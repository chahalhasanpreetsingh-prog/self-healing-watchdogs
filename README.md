# self-healing-watchdogs

Two production watchdogs built on one pattern: **check cheaply, fix deterministically, and only
then wake an AI agent** — with a scoped tool allow-list, a cooldown, and verification that the
service is actually back.

Both run unattended on my homelab. They are the scripts, not a framework: read them as worked
examples of how to let an LLM touch production without handing it the keys.

```
timer ─► cheap check ──healthy──► exit silently
             │ failing
             ▼
        re-check after 30 s  ──cleared──► "blip", exit
             │ still failing
             ▼
     deterministic recovery (the fix that worked last time)
             │ still failing
             ▼
   headless `claude -p` with a FIXED --allowedTools list, 20-min timeout,
   30-min cooldown, one-shot, no background work
             │
             ▼
        re-check ──► record FIXED / STILL DOWN in the journal
```

## The rules that make it safe

- **The agent is the last resort, not the first.** Every failure this had actually seen is handled
  by scripted recovery first: `compose up`, wait for Postgres to accept connections, restart the
  API, restart the tunnel. The LLM is only paid for genuinely novel failures.
- **A fixed allow-list, never `--dangerously-skip-permissions`.** The agent gets
  `docker ps/logs/inspect/restart/compose up`, prune, `curl`, `df`, `free`, `journalctl`,
  `systemctl status` and exactly one privileged action: restarting the tunnel service. The prompt
  states that anything else is refused and tells it to report what it would need instead.
- **Explicit prohibitions:** never delete volumes, never touch database data, never change code
  or config.
- **Cooldown + lock.** One agent session per 30 minutes, and `flock` so runs never stack — a fix
  session can take 20 minutes while the timer fires every 2.
- **Success is measured, not claimed.** The watchdog re-runs its own checks after the agent exits
  and records FIXED or STILL DOWN. The agent's summary is journal output, not the verdict.
- **Deploys are respected:** if a deploy is in progress, the watchdog exits rather than
  "recovering" containers that are restarting on purpose.

## The two examples

**`examples/api-stack-watchdog.sh`** — a Dockerised FastAPI/Postgres/Redis/Celery stack behind a
Cloudflare tunnel. Checks containers, `pg_isready`, a Redis `PING`, and `/health` both locally and
publicly. It was written around a real failure: the API started before Postgres finished recovery,
the uvicorn `--reload` parent survived with no worker, and the container reported "Up" while the
port reset. A container-level health check would have seen nothing — so the check proves a worker
answers, and recovery waits for the database before touching the API. Paired prompt:
`examples/api-stack-fix-prompt.md`.

**`examples/bluetooth-audio-watchdog.sh`** — a morning-music routine on a Windows machine driven
over SSH. Its lesson: **"the player is running" is not "sound is audible"**. When the Bluetooth
link dropped, Windows silently moved playback to the internal speakers and the player kept
running, so the log said SUCCESS every morning while the room was silent. The check now requires
both a live player *and* the Bluetooth speaker as the current default output device. It also
handles CRLF (a trailing `\r` made every string compare silently false) and drives PowerShell via
`-EncodedCommand`, because the remote shell is `cmd.exe` and mangles quoted regexes.

## Use

Both scripts read their environment (`COMPOSE_DIR`, `AGENT_URL`, `AGENT_TOKEN`, `SPEAKER_NAME`)
and expect [Claude Code](https://docs.claude.com/claude-code) on PATH. Run one from a systemd
timer or cron, and read results with `journalctl --user -u <unit>`.

MIT licensed.
