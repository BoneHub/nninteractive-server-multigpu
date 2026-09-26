#!/bin/sh
# Entrypoint of the proxy container, see compose.yaml. Checks the keys from .env,
# writes them into /etc/nginx/users.conf (included by nginx.conf) and starts nginx.
# A key that breaks the rules stops the proxy with a message naming the key.
set -euf

fail() {
    echo "proxy-start.sh: $*" >&2
    exit 1
}

# The rules for every key, see .env.example. Letters and digits only also means
# that a key cannot break the nginx configuration it is written into.
check_key() {  # <which key> <value>
    case $2 in
        '') fail "$1 is empty" ;;
        *[!A-Za-z0-9]*) fail "$1 may contain only letters and digits" ;;
    esac
    [ "${#2}" -ge 16 ] || fail "$1 is shorter than 16 characters"
    [ "${#2}" -le 128 ] || fail "$1 is longer than 128 characters"
}

# nginx matches keys regardless of upper or lower case, so the checks do too.
lower() {
    printf '%s' "$1" | tr 'A-Z' 'a-z'
}

check_key INTERNAL_API_KEY "${INTERNAL_API_KEY:-}"
internal=$(lower "$INTERNAL_API_KEY")

nl='
'
gpu_map=
user_map=
seen=' '
total=0

# The number of every GPU<number>_USER_KEYS variable in .env, in order.
for n in $(env | sed -n 's/^GPU\([0-9][0-9]*\)_USER_KEYS=.*/\1/p' | sort -n); do
    eval "keys=\$GPU${n}_USER_KEYS"
    i=0
    # Keys are separated by commas and/or spaces.
    for key in $(printf '%s' "$keys" | tr ',' ' '); do
        i=$((i + 1))
        what="key $i in GPU${n}_USER_KEYS"
        check_key "$what" "$key"
        key_lower=$(lower "$key")
        [ "$key_lower" != "$internal" ] || fail "$what is the same as INTERNAL_API_KEY"
        case $seen in
            *" $key_lower "*) fail "$what appears twice in .env" ;;
        esac
        seen="$seen$key_lower "
        gpu_map="$gpu_map    \"Bearer $key\" nn$n;$nl"
        user_map="$user_map    \"Bearer $key\" gpu$n-user$i;$nl"
    done
    echo "proxy-start.sh: GPU $n (service nn$n): $i user key(s)"
    total=$((total + i))
done
[ "$total" -gt 0 ] || fail "no user keys: set GPU0_USER_KEYS and so on in .env"

umask 077
cat > /etc/nginx/users.conf <<EOF
# Written by proxy-start.sh from .env when the proxy started. Do not edit it:
# change .env and run "docker compose up -d".

# GPU service of each user key; "" for an unknown key.
map \$http_authorization \$nn_gpu {
    default "";
$gpu_map}

# Each user for the log: gpu0-user2 is the 2nd key in GPU0_USER_KEYS.
map \$http_authorization \$nn_user {
    default "-";
$user_map}

# Sent to the GPU containers in place of the user's key.
map \$http_authorization \$nn_internal_auth {
    default "Bearer $INTERNAL_API_KEY";
}
EOF

# Start nginx, or run the command given, e.g. docker compose run --rm proxy nginx -t
[ "$#" -gt 0 ] || set -- nginx -g 'daemon off;'
exec "$@"
