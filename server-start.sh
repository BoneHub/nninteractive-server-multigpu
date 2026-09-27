#!/bin/sh
# Entrypoint of the users' server containers, see compose.yaml. Starts the
# nnInteractive server on the GPU of this container's user (NN_GPU, set in
# compose.override.yaml) with MAX_SESSIONS_PER_USER sessions (.env). Options from
# "command:" in compose.yaml come after these, so a --device or --max-sessions
# there wins.
set -euf

fail() {
    echo "server-start.sh: $*" >&2
    exit 1
}

case ${NN_GPU:-} in
    '' | *[!0-9]*) fail "NN_GPU is not a GPU number: '${NN_GPU:-}'. Run: docker compose run --rm configure" ;;
esac
case ${MAX_SESSIONS_PER_USER:-} in
    '' | *[!0-9]*) fail "MAX_SESSIONS_PER_USER in .env is not a number: '${MAX_SESSIONS_PER_USER:-}'" ;;
esac
[ "$MAX_SESSIONS_PER_USER" -ge 1 ] || fail "MAX_SESSIONS_PER_USER in .env must be 1 or more"

# The container sees all GPUs. Name a missing one here rather than in a CUDA error.
if gpus=$(nvidia-smi -L 2>/dev/null); then
    count=$(printf '%s\n' "$gpus" | grep -c '^GPU ' || true)
    [ "$NN_GPU" -lt "$count" ] ||
        fail "GPU $NN_GPU does not exist: this machine has $count GPU(s), numbered from 0 (nvidia-smi -L). Fix the GPU${NN_GPU}_USER_KEYS line in .env."
fi

echo "server-start.sh: starting the server on GPU $NN_GPU with --max-sessions $MAX_SESSIONS_PER_USER"
exec nninteractive-entrypoint --device "cuda:$NN_GPU" --max-sessions "$MAX_SESSIONS_PER_USER" "$@"
