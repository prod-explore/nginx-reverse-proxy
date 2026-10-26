#!/usr/bin/env bash
# Validate the whole configuration with the same nginx image the proxy runs on:
# runs `nginx -t` on every site example together, each with a throwaway
# certificate, then on the before-certificate example alone, with none.
# Needs docker on a host with IPv6 enabled in the kernel (`nginx -t` opens the
# [::] listeners) and openssl. Used by CI; run it before every commit.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/fixtures.sh
. scripts/fixtures.sh

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

nginx_t() {
  docker run --rm \
    -v "$PWD/nginx:$(dirname "$conf"):ro" \
    -v "$work/sites:/etc/nginx/sites:ro" \
    -v "$work/certs:/etc/letsencrypt:ro" \
    -v "$work/webroot:/var/www/certbot:ro" \
    "$image" nginx -c "$conf" -t
}

# Every site example together, each with its certificate.
make_fixtures "$work"
nginx_t

# The before-certificate example must be valid on its own, with no certificate.
rm -rf "$work/sites"/*.conf "$work/certs"/*
cp examples/site-before-certificate.conf.example "$work/sites/site-before-certificate.conf"
chmod -R a+rX "$work"
nginx_t

echo "nginx configuration OK"
