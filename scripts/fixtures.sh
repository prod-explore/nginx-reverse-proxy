# shellcheck shell=bash
# Shared by check.sh and smoke-test.sh (sourced, not run, from the repository root).

# Read from docker-compose.yml, so that the tests cannot drift from production:
# the nginx image, and the path of the configuration inside the container (where
# nginx/ is mounted, which relative includes depend on).
# shellcheck disable=SC2034  # used by the scripts that source this file
image=$(sed -n 's|^[[:space:]]*image: \(nginx:[^[:space:]]*\)$|\1|p' docker-compose.yml | head -1)
: "${image:?could not read the nginx image from docker-compose.yml}"
conf=$(sed -n 's|^[[:space:]]*NGINX_CONF: \([^[:space:]]*\)$|\1|p' docker-compose.yml | head -1)
: "${conf:?could not read NGINX_CONF from docker-compose.yml}"

# make_fixtures DIR: fills DIR/sites with every examples/*.conf.example except
# site-before-certificate, DIR/certs with a throwaway self-signed certificate for
# each domain those examples reference, and creates an empty DIR/webroot.

make_fixtures() {
  local dir=$1 f domain
  mkdir -p "$dir/sites" "$dir/certs" "$dir/webroot"

  for f in examples/*.conf.example; do
    cp "$f" "$dir/sites/$(basename "${f%.example}")"
  done
  # site-before-certificate.conf and site.conf both claim app.example.com: the
  # pair is a before/after, never loaded together.
  rm "$dir/sites/site-before-certificate.conf"

  while read -r domain; do
    mkdir -p "$dir/certs/live/$domain"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$domain" \
      -keyout "$dir/certs/live/$domain/privkey.pem" \
      -out "$dir/certs/live/$domain/fullchain.pem" 2>/dev/null
  done < <(grep -hoE 'live/[a-z0-9.-]+/fullchain' examples/*.conf.example | cut -d/ -f2 | sort -u)

  # nginx runs as a different uid in the container; make the throwaway tree readable.
  chmod -R a+rX "$dir"
}
