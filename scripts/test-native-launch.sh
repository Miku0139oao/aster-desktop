#!/usr/bin/env bash
# Smoke-test the real window process without modifying the user's configuration.
set -euo pipefail
app="$1"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/aster-native.XXXXXX")"
owner=
cleanup() {
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    kill -TERM "$owner" 2>/dev/null || true
    for attempt in $(seq 1 50); do
      if ! kill -0 "$owner" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if kill -0 "$owner" 2>/dev/null; then
      kill -KILL "$owner" 2>/dev/null || true
    fi
    wait "$owner" || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT
"$app" --data "$scratch/data" >"$scratch/app.log" 2>&1 &
owner=$!
for attempt in $(seq 1 120); do
  if [ -f "$scratch/data/desktop.lock" ]; then break; fi
  if ! kill -0 "$owner" 2>/dev/null; then cat "$scratch/app.log"; exit 1; fi
  sleep 0.1
done
test -f "$scratch/data/desktop.lock" || { cat "$scratch/app.log"; exit 1; }
# The second copy must send activation and exit. Bound both launches so CI
# never leaves an extra app running if the lease regresses.
python3 - "$app" "$scratch/data" <<'PY'
import subprocess, sys
subprocess.run([sys.argv[1], "--data", sys.argv[2]], check=True, timeout=18)
PY
kill -0 "$owner"
kill -TERM "$owner"
for attempt in $(seq 1 120); do
  if ! kill -0 "$owner" 2>/dev/null; then break; fi
  sleep 0.1
done
if kill -0 "$owner" 2>/dev/null; then
  cat "$scratch/app.log"
  kill -KILL "$owner" 2>/dev/null || true
  exit 1
fi
wait "$owner" || { cat "$scratch/app.log"; exit 1; }
owner=
