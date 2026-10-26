#!/usr/bin/env bash
# Apply a change under nginx/ or sites/ to the running proxy: test the whole
# configuration inside the container and reload only if the test passes. A
# failed test changes nothing; the running configuration keeps serving.
#
# Arguments are passed to `docker compose` before `exec`, to address another
# project (smoke-test.sh passes -p and -f).
set -euo pipefail

cd "$(dirname "$0")/.."

# NGINX_CONF is set in docker-compose.yml. Without -c, nginx would test and
# signal the image's default configuration instead of this one.
# shellcheck disable=SC2016  # expanded by the shell inside the container
docker compose "$@" exec -T nginx sh -c 'nginx -c "$NGINX_CONF" -t && nginx -c "$NGINX_CONF" -s reload'
