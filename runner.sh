#!/bin/bash
# inferno-runner: keep re-running build.sh until InfernoData.zip exists.
# Pulls this repo before every run, so a pushed fix is picked up on the
# next cycle automatically. Pushes logs back after every run. Stops after
# 6 failures on the same build revision, or when a STOP file appears.
DIR="$HOME/inferno-runner"
BUILD_DIR="$HOME/InfernoMacBuild"
ZIP="$BUILD_DIR/InfernoData.zip"
mkdir -p "$DIR/logs"
cd "$DIR" || exit 1
git config user.name "user"
git config user.email "user@users.noreply.github.com"
LASTSHA=""
STRIKES=0
echo "runner started $(date)"
while [ ! -f "$ZIP" ]; do
  if [ -f "$DIR/STOP" ]; then echo "STOP file present - runner exiting"; break; fi
  git pull -q --ff-only 2>/dev/null || true
  SHA=$(git rev-parse HEAD 2>/dev/null || echo none)
  if [ "$SHA" != "$LASTSHA" ]; then LASTSHA="$SHA"; STRIKES=0; fi
  STAMP=$(date +%Y%m%d-%H%M%S)
  echo "=== run $STAMP (build $SHA, strike $STRIKES) ==="
  caffeinate -i bash "$DIR/build.sh" > "$DIR/logs/run-$STAMP.log" 2>&1
  EC=$?
  docker exec inferno1 ssh -i /work/keys/id_ed25519 -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p 2222 inferno@127.0.0.1 "cat ~/restore.log" > "$DIR/logs/restore-$STAMP.log" 2>/dev/null || true
  cp "$BUILD_DIR"/logs/panic-attempt-*.log "$DIR/logs/" 2>/dev/null || true
  cp "$BUILD_DIR"/logs/iphone-serial.log "$DIR/logs/serial-$STAMP.log" 2>/dev/null || true
  if [ -f "$ZIP" ]; then
    echo "SUCCESS $(date) exit=$EC" > "$DIR/state.txt"
  else
    STRIKES=$((STRIKES+1))
    echo "FAILED $(date) exit=$EC strikes=$STRIKES build=$SHA" > "$DIR/state.txt"
  fi
  git add -A >/dev/null 2>&1
  git commit -q -m "run $STAMP exit=$EC" >/dev/null 2>&1 || true
  git push -q >/dev/null 2>&1 || echo "warning: log push failed (retried next run)"
  if [ -f "$ZIP" ]; then echo "InfernoData.zip is ready - runner done"; break; fi
  if [ "$STRIKES" -ge 6 ]; then
    echo "NEEDS-HUMAN $(date) six failures on build $SHA" > "$DIR/state.txt"
    git add -A >/dev/null 2>&1; git commit -q -m "needs human" >/dev/null 2>&1 || true; git push -q >/dev/null 2>&1 || true
    echo "Six failures on the same build - stopping for a human. See state.txt and logs/."
    break
  fi
  echo "run failed (exit $EC) - waiting 60s, then pulling any fix and retrying"
  sleep 60
done
