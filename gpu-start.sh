#!/bin/sh
# Entrypoint of the GPU containers, see compose.yaml. Starts the nnInteractive
# server with one session per user of this GPU: --max-sessions is the number of
# keys in USER_KEYS (this GPU's GPU<number>_USER_KEYS line in .env). Options
# from "command:" in compose.yaml come after it, so a --max-sessions there wins.
set -euf

users=0
# Keys are separated by commas and/or spaces.
for _ in $(printf '%s' "${USER_KEYS:-}" | tr ',' ' '); do
    users=$((users + 1))
done
if [ "$users" -eq 0 ]; then
    echo "gpu-start.sh: USER_KEYS is empty" >&2
    exit 1
fi

echo "gpu-start.sh: $users user key(s), starting the server with --max-sessions $users"
exec nninteractive-entrypoint --max-sessions "$users" "$@"
