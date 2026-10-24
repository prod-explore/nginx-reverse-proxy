#!/usr/bin/env bash
# Validate the whole configuration with the same nginx image the proxy runs on:
# copies every examples/*.conf.example into a throwaway sites/ directory, creates
# throwaway certificates for the example domains and runs `nginx -t`.
# Needs docker and openssl. Used by CI; run it before every commit.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/fixtures.sh
. scripts/fixtures.sh

image=$(sed -n 's|^[[:space:]]*image: \(nginx:[^[:space:]]*\)$|\1|p' docker-compose.yml | head -1)
: "${image:?could not read the nginx image from docker-compose.yml}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

nginx_t() {
  docker run --rm \
    -v "$PWD/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$PWD/nginx/snippets:/etc/nginx/snippets:ro" \
    -v "$PWD/nginx/conf.d:/etc/nginx/conf.d:ro" \
    -v "$work/sites:/etc/nginx/sites:ro" \
    -v "$work/certs:/etc/letsencrypt:ro" \
    -v "$work/webroot:/var/www/certbot:ro" \
    "$image" nginx -t
}

# Every site example together, each with its certificate.
make_fixtures "$work"
nginx_t

# The bootstrap example must be valid on its own, before any certificate exists.
rm -rf "$work/sites"/*.conf "$work/certs"/*
cp examples/bootstrap.conf.example "$work/sites/bootstrap.conf"
chmod -R a+rX "$work"
nginx_t

echo "nginx configuration OK"
