#!/usr/bin/env bash
# Validate the whole configuration with the same nginx image the proxy runs on:
# copies every examples/*.conf.example into a throwaway sites/ directory, creates
# throwaway certificates for the example domains and runs `nginx -t`.
# Needs docker and openssl. Used by CI; run it before every commit.
set -euo pipefail

cd "$(dirname "$0")/.."
image=$(sed -n 's|^[[:space:]]*image: \(nginx:[^[:space:]]*\)$|\1|p' docker-compose.yml | head -1)
: "${image:?could not read the nginx image from docker-compose.yml}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/sites" "$work/webroot"

# The bootstrap example has no certificate by design; the others need one each.
for f in examples/*.conf.example; do
  cp "$f" "$work/sites/$(basename "${f%.example}")"
done
while read -r domain; do
  mkdir -p "$work/certs/live/$domain"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$domain" \
    -keyout "$work/certs/live/$domain/privkey.pem" -out "$work/certs/live/$domain/fullchain.pem" 2>/dev/null
done < <(grep -hoE 'live/[a-z0-9.-]+/fullchain' examples/*.conf.example | cut -d/ -f2 | sort -u)

# nginx runs as a different uid in the container; make the throwaway tree readable.
chmod -R a+rX "$work"

# bootstrap.conf and site.conf both claim app.example.com: the pair is a before/after, never loaded together.
rm "$work/sites/bootstrap.conf"

docker run --rm \
  -v "$PWD/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$PWD/nginx/snippets:/etc/nginx/snippets:ro" \
  -v "$PWD/nginx/conf.d:/etc/nginx/conf.d:ro" \
  -v "$work/sites:/etc/nginx/sites:ro" \
  -v "$work/certs:/etc/letsencrypt:ro" \
  -v "$work/webroot:/var/www/certbot:ro" \
  "$image" nginx -t

# The bootstrap example must be valid on its own too.
rm "$work/sites"/*.conf
cp examples/bootstrap.conf.example "$work/sites/bootstrap.conf"
chmod -R a+rX "$work"
docker run --rm \
  -v "$PWD/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$PWD/nginx/snippets:/etc/nginx/snippets:ro" \
  -v "$PWD/nginx/conf.d:/etc/nginx/conf.d:ro" \
  -v "$work/sites:/etc/nginx/sites:ro" \
  -v "$work/webroot:/var/www/certbot:ro" \
  "$image" nginx -t
echo "nginx configuration OK"
