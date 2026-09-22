#!/bin/bash
# Morning-music watchdog — cron 09:05 IST daily.
# Happy path: cheap deterministic check, no Claude invocation, ~2 SSH calls.
# Failure path: launches a headless Claude Code session to diagnose + fix + log.
set -u
DIR=$HOME/morning-music-watchdog
LOG=$DIR/watchdog.log
STAMP() { date '+%Y-%m-%d %H:%M:%S'; }

SSH="ssh -o BatchMode=yes -o ConnectTimeout=15 laptop"

# "mpv is running" is NOT the same as "music is audible". When the A2DP link drops,
# Windows silently moves playback to the internal Realtek speakers and mpv keeps running
# perfectly happily -- which is why this log read "SUCCESS - music playing" every morning
# while the room was silent (2026-08-03/04). Require BOTH a live mpv AND the Stanmore as
# the current default output device.
#
# EncodedCommand because the laptop's SSH shell is cmd.exe, which mangles pipes and
# quoted regexes inside `powershell -Command "..."`.
PS_CHECK=$(printf '%s' "Import-Module AudioDeviceCmdlets -ErrorAction SilentlyContinue
\$m = [bool](Get-Process mpv -ErrorAction SilentlyContinue)
\$d = [bool](Get-AudioDevice -List | Where-Object { \$_.Type -eq 'Playback' -and \$_.Default -and \$_.Name -match '${SPEAKER_NAME:-YOUR-SPEAKER}' })
if (\$m -and \$d) { 'PLAYING' } elseif (\$m) { 'WRONG-DEVICE' } else { 'NOT-PLAYING' }" \
  | iconv -f UTF-8 -t UTF-16LE | base64 -w0)

# tr -d '\r' matters: Windows emits CRLF, and a trailing CR made every string compare
# below silently false.
check_mpv() {
  $SSH "powershell -NoProfile -EncodedCommand $PS_CHECK" 2>/dev/null | tr -d '\r' | head -1
}

R1=$(check_mpv)
if [ "$R1" = "PLAYING" ]; then
  echo "[$(STAMP)] OK — mpv running on laptop, morning music healthy." >> "$LOG"
  exit 0
fi

# mpv briefly exits between songs — re-check once after 25s before declaring failure.
sleep 25
R2=$(check_mpv)
if [ "$R2" = "PLAYING" ]; then
  echo "[$(STAMP)] OK — mpv running on second check (song gap), morning music healthy." >> "$LOG"
  exit 0
fi

echo "[$(STAMP)] FAILURE detected (check1=$R1, check2=$R2) — running deterministic recovery." >> "$LOG"

# Deterministic recovery: the exact sequence that worked on 2026-07-10.
# Agent /bt/connect runs bt-preconnect.ps1 (3 radio-restart cycles since 07-10).
AGENT="${AGENT_URL:?set AGENT_URL=http://<host>:3391}"
TOK="${AGENT_TOKEN:?set AGENT_TOKEN}"
CONNECTED=0
for round in 1 2; do
  curl -s -m 20 -X POST -H "X-Nexus-Agent-Token: $TOK" -d "" $AGENT/bt/connect > /dev/null
  for i in $(seq 1 24); do   # poll up to 4 min per round
    sleep 10
    if curl -s -m 15 -H "X-Nexus-Agent-Token: $TOK" $AGENT/bt/status | grep -q '"connected":true'; then
      CONNECTED=1; break
    fi
  done
  [ "$CONNECTED" = 1 ] && break
  echo "[$(STAMP)] BT connect round $round failed." >> "$LOG"
done

DET_OK=0
if [ "$CONNECTED" = 1 ]; then
  # Re-run the morning TASK rather than agent /media/start: the task's script opens with
  # Aarti and self-stops after 30 min, whereas /media/start runs nexus-shuffle-loop.ps1
  # (pure shuffle, no opener, loops forever) — that path silently dropped the opener on
  # every watchdog-rescued morning. /media/start stays as-is for the dashboard play button.
  echo "[$(STAMP)] Speaker connected — re-running Navidrome-Morning-Music task." >> "$LOG"
  $SSH "schtasks /Run /TN Navidrome-Morning-Music" > /dev/null 2>&1
  sleep 20
  # Agent /media/status only knows whether an mpv process exists -- it cannot tell the
  # speaker from the internal speakers. Use the device-aware check instead.
  DET_STATE=$(check_mpv)
  if [ "$DET_STATE" = "PLAYING" ]; then
    echo "[$(STAMP)] Deterministic recovery SUCCESS — music playing on the speaker." >> "$LOG"
    DET_OK=1
  elif [ "$DET_STATE" = "WRONG-DEVICE" ]; then
    echo "[$(STAMP)] mpv is running but output is NOT the Stanmore — treating as failure." >> "$LOG"
  fi
fi

# Claude fixer is the LAST resort, only if the deterministic path failed.
if [ "$DET_OK" != 1 ]; then
  echo "[$(STAMP)] Deterministic recovery failed — launching Claude fixer session." >> "$LOG"
  cd $HOME || exit 1
  timeout 20m $HOME/.npm-global/bin/claude -p "$(cat "$DIR/fix-prompt.md")" \
    --dangerously-skip-permissions >> "$DIR/claude-session.log" 2>&1
  RC=$?
  echo "[$(STAMP)] Claude fixer session exited rc=$RC (full transcript in claude-session.log)." >> "$LOG"
fi

# Final verdict line so the morning log always states the outcome even if Claude crashed.
# The device-aware check is authoritative here; the agent's process-only view is not a
# valid fallback because it reports "playing" for audio going to the wrong device.
R3=$(check_mpv)
echo "[$(STAMP)] Post-fix state: ${R3:-ssh-unreachable}." >> "$LOG"

# Morning music window is 9:00-9:30. The task's script self-stops 30 min after it starts,
# but a late re-run overruns that, and the Claude fixer may still fall back to agent
# /media/start (loops forever) — so enforce the cutoff here for both paths.
if [ "$R3" = "PLAYING" ]; then
  NOW=$(date +%s); CUTOFF=$(date -d '09:35' +%s)
  [ "$NOW" -lt "$CUTOFF" ] && sleep $((CUTOFF - NOW))
  # End the task FIRST: /media/stop only kills mpv, and the morning script's loop would
  # simply start the next song. /End stops the script itself; /media/stop then clears
  # any mpv left by the nexus-shuffle-loop path.
  $SSH "schtasks /End /TN Navidrome-Morning-Music" > /dev/null 2>&1
  curl -s -m 15 -X POST -H "X-Nexus-Agent-Token: $TOK" \
    -d "" $AGENT/media/stop > /dev/null
  echo "[$(STAMP)] Enforced 9:30 window cutoff — task ended and music stopped." >> "$LOG"
fi
