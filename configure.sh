#!/bin/sh
# Writes compose.override.yaml from .env: one nnInteractive server service per user
# key. The i-th key in GPU<number>_USER_KEYS gets the service gpu<number>-user<i>, a
# copy of the "nninteractive" service in compose.yaml that computes on GPU <number>.
# Runs in a container, see "configure" in compose.yaml:
#   docker compose run --rm configure
# It only counts the keys; the proxy checks the keys themselves when it starts.
set -euf

fail() {
    echo "configure.sh: $*" >&2
    exit 1
}

out=/project/compose.override.yaml
header='# Written by configure.sh from .env. Do not edit: it is overwritten.'

# Never overwrite a compose.override.yaml written by hand.
if [ -e "$out" ] && [ "$(head -n 1 "$out")" != "$header" ]; then
    fail "compose.override.yaml was not written by configure.sh. Move your settings from it to compose.yaml, delete it and run this again."
fi

services=
body=

# The number of every GPU<number>_USER_KEYS variable in .env, in order.
for n in $(env | sed -n 's/^GPU\([0-9][0-9]*\)_USER_KEYS=.*/\1/p' | sort -n); do
    case $n in
        0?*) fail "GPU${n}_USER_KEYS: write the GPU number without leading zeros" ;;
    esac
    eval "keys=\$GPU${n}_USER_KEYS"
    i=0
    # Keys are separated by commas and/or spaces, as in proxy-start.sh.
    for _ in $(printf '%s' "$keys" | tr ',' ' '); do
        i=$((i + 1))
        service=gpu$n-user$i
        services="${services:+$services }$service"
        body="$body
  $service:
    extends: {file: compose.yaml, service: nninteractive}
    scale: 1
    environment:
      NN_GPU: \"$n\"
"
    done
    echo "configure.sh: GPU $n: $i user(s)"
done
[ -n "$services" ] || fail "no user keys: set GPU0_USER_KEYS and so on in .env"

cat > "$out" <<EOF
$header
# One server container per user key in .env: gpu0-user2 is the 2nd key in
# GPU0_USER_KEYS. After adding or removing keys or GPU lines in .env, write it
# again and apply it:
#   docker compose run --rm configure
#   docker compose up -d --remove-orphans

services:$body
  # The proxy starts only while these services match the keys in .env, see
  # proxy-start.sh.
  proxy:
    environment:
      NN_USER_SERVICES: "$services"
EOF
# Linux: give the file the owner of the project folder instead of root.
chown "$(stat -c %u:%g /project)" "$out" 2>/dev/null || true

echo "configure.sh: wrote compose.override.yaml: $services"
echo "configure.sh: now run: docker compose up -d --remove-orphans"
