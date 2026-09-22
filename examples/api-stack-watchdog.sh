#!/bin/bash
# Dump backend watcher — systemd user timer, every 2 min.
# Happy path: a few curls + docker inspects, silent. Failure path: re-check after 30 s,
# deterministic fix, and only if that fails a headless Claude session (scoped tool
# allow-list, no skip-permissions) diagnoses and fixes it.
set -u
DIR=$HOME/dump-watchdog
STATE=$DIR/state            # last verdict: OK / DOWN
CLAUDE_STAMP=$DIR/last-claude-run
COMPOSE_DIR="${COMPOSE_DIR:?set COMPOSE_DIR}"
CONTAINERS="backend-db-1 backend-redis-1 backend-api-1 backend-worker-1 backend-beat-1 backend-cobalt-1"
CLAUDE_COOLDOWN=1800        # at most one Claude session per 30 min on a persistent failure
STAMP() { date '+%Y-%m-%d %H:%M:%S'; }
# No log files: stdout goes to the journal (size-capped, auto-rotated).
# Read with: journalctl --user -u dump-watchdog
log() { echo "$*"; }

exec 9>"$DIR/.lock"; flock -n 9 || exit 0      # never stack runs (a Claude fix can take 20 min)
pgrep -f 'deploy\.sh' >/dev/null && exit 0     # a deploy restarts containers on purpose

http() { curl -s -o /dev/null -w '%{http_code}' -m 10 "$1"; }

# Prints nothing when healthy, else a space-separated list of problems.
check() {
  local p="" c
  for c in $CONTAINERS; do
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || p+="$c:not-running "
  done
  docker exec backend-db-1 pg_isready -U dump -q 2>/dev/null || p+="db:not-ready "
  [ "$(docker exec backend-redis-1 redis-cli ping 2>/dev/null)" = PONG ] || p+="redis:no-pong "
  # /health doesn't touch the DB, but it proves a uvicorn worker is alive — the 09-18 failure
  # mode was a live --reload parent with no worker (container "Up", port resets).
  [ "$(http http://127.0.0.1:8000/health)" = 200 ] || p+="api-local:$(http http://127.0.0.1:8000/health) "
  [ "$(http https://api.example.com/health)" = 200 ] || p+="api-public:$(http https://api.example.com/health) "
  echo "$p"
}

P1=$(check)
if [ -z "$P1" ]; then
  [ "$(cat "$STATE" 2>/dev/null)" = DOWN ] && log "RECOVERED — all checks pass."
  echo OK > "$STATE"; exit 0
fi
sleep 30                                          # ride out blips / container restarts
P2=$(check)
if [ -z "$P2" ]; then log "blip (cleared in 30 s): $P1"; echo OK > "$STATE"; exit 0; fi

echo DOWN > "$STATE"
log "DOWN: $P2 — deterministic recovery."

# 1) anything not running → compose up (brings the stack back in dependency order)
if echo "$P2" | grep -q not-running; then
  (cd "$COMPOSE_DIR" && docker compose up -d) 2>&1
fi
# 2) wait for the DB before touching the API (the 09-18 race)
for i in $(seq 1 30); do docker exec backend-db-1 pg_isready -U dump -q 2>/dev/null && break; sleep 2; done
# 3) API dead locally → restart it (fixes the orphaned --reload parent)
if echo "$P2" | grep -q api-local; then docker restart backend-api-1 >/dev/null 2>&1; fi
for i in $(seq 1 12); do [ "$(http http://127.0.0.1:8000/health)" = 200 ] && break; sleep 5; done
# 4) local fine but public dead → the tunnel
if [ "$(http http://127.0.0.1:8000/health)" = 200 ] && [ "$(http https://api.example.com/health)" != 200 ]; then
  log "local OK, public down — restarting cloudflared."
  sudo -n systemctl restart cloudflared; sleep 15
fi

P3=$(check)
if [ -z "$P3" ]; then log "FIXED by deterministic recovery."; echo OK > "$STATE"; exit 0; fi

# 5) last resort: wake Claude, with a scoped allow-list (no --dangerously-skip-permissions)
NOW=$(date +%s); LAST=$(cat "$CLAUDE_STAMP" 2>/dev/null || echo 0)
if [ $((NOW - LAST)) -lt $CLAUDE_COOLDOWN ]; then
  log "still DOWN ($P3) — Claude ran $(( (NOW-LAST)/60 )) min ago, cooldown; not relaunching."
  exit 1
fi
echo "$NOW" > "$CLAUDE_STAMP"
log "still DOWN after deterministic recovery: $P3 — launching Claude fixer."
cd $HOME || exit 1
OUT=$(timeout 20m $HOME/.npm-global/bin/claude -p \
  "$(cat "$DIR/fix-prompt.md")

Current failing checks: $P3
Recent watcher journal:
$(journalctl --user -u dump-watchdog -n 30 --no-pager -o short 2>/dev/null)" \
  --allowedTools "Read" "Grep" "Glob" \
    "Bash(docker ps:*)" "Bash(docker logs:*)" "Bash(docker inspect:*)" "Bash(docker restart:*)" \
    "Bash(docker start:*)" "Bash(docker compose up:*)" "Bash(docker compose ps:*)" "Bash(docker exec backend-db-1 pg_isready:*)" \
    "Bash(docker system df:*)" "Bash(docker builder prune:*)" "Bash(docker image prune:*)" \
    "Bash(curl:*)" "Bash(sleep:*)" "Bash(df:*)" "Bash(free:*)" "Bash(findmnt:*)" "Bash(journalctl:*)" \
    "Bash(systemctl status:*)" "Bash(sudo systemctl restart cloudflared)" "Bash(sudo systemctl status:*)" 2>&1)
RC=$?
echo "===== Claude transcript (problems: $P3, rc=$RC)"; echo "$OUT"
log "CLAUDE (rc=$RC): $(echo "$OUT" | tail -6 | tr '\n' ' ' | cut -c1-600)"
P4=$(check)
if [ -z "$P4" ]; then log "FIXED by Claude session."; echo OK > "$STATE"
else log "Claude session ended, STILL DOWN: $P4"; fi
