#!/bin/sh
# Entrypoint of the proxy container, see compose.yaml. Checks the keys from .env,
# writes them into /etc/nginx/users.conf (included by nginx.conf) and starts nginx.
# A key that breaks the rules stops the proxy with a message naming the key, and so
# does a key without its server container (configure.sh not run after changing .env).
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
    # There is no minimum length. Warning: the key is the only thing that keeps
    # others off the GPUs, and a short key (e.g. "alice" or "1234") is easy to
    # guess by anyone who can reach PUBLIC_PORT. Use short keys only when the
    # port is reachable from trusted machines alone; otherwise use random keys
    # of 16 or more characters (openssl rand -hex 16). To enforce that, remove
    # the # in front of the next line.
    # [ "${#2}" -ge 16 ] || fail "$1 is shorter than 16 characters"
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
user_map=
services=
seen=' '

# The number of every GPU<number>_USER_KEYS variable in .env, in order.
for n in $(env | sed -n 's/^GPU\([0-9][0-9]*\)_USER_KEYS=.*/\1/p' | sort -n); do
    case $n in
        0?*) fail "GPU${n}_USER_KEYS: write the GPU number without leading zeros" ;;
    esac
    eval "keys=\$GPU${n}_USER_KEYS"
    i=0
    # Keys are separated by commas and/or spaces, as in configure.sh.
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
        service=gpu$n-user$i
        services="${services:+$services }$service"
        user_map="$user_map    \"Bearer $key\" $service;$nl"
    done
    echo "proxy-start.sh: GPU $n: $i user key(s)"
done
[ -n "$services" ] || fail "no user keys: set GPU0_USER_KEYS and so on in .env"

# Every key needs its server container. configure.sh wrote the list of containers
# into compose.override.yaml (NN_USER_SERVICES); it is out of date when keys or GPU
# lines were added to or removed from .env since.
[ "$services" = "${NN_USER_SERVICES:-}" ] || fail "the server containers do not match the keys in .env.
  .env needs:            $services
  compose.override.yaml: ${NN_USER_SERVICES:-(none)}
Run  docker compose run --rm configure  and then  docker compose up -d --remove-orphans"

umask 077
cat > /etc/nginx/users.conf <<EOF
# Written by proxy-start.sh from .env when the proxy started. Do not edit it:
# change .env and run "docker compose up -d".

# Server container (compose service) of each user key: gpu0-user2 is the 2nd key
# in GPU0_USER_KEYS; "" for an unknown key.
map \$http_authorization \$nn_user {
    default "";
$user_map}

# Sent to the server containers in place of the user's key.
map \$http_authorization \$nn_internal_auth {
    default "Bearer $INTERNAL_API_KEY";
}
EOF

# Start nginx, or run the command given, e.g. docker compose run --rm proxy nginx -t
[ "$#" -gt 0 ] || set -- nginx -g 'daemon off;'
exec "$@"
