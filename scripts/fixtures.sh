# shellcheck shell=bash
# Shared by check.sh and smoke-test.sh (sourced, not run).
#
# make_fixtures DIR: fills DIR/sites with every examples/*.conf.example except the
# bootstrap one, DIR/certs with a throwaway self-signed certificate for each domain
# those examples reference, and creates an empty DIR/webroot.

make_fixtures() {
  local dir=$1 f domain
  mkdir -p "$dir/sites" "$dir/certs" "$dir/webroot"

  for f in examples/*.conf.example; do
    cp "$f" "$dir/sites/$(basename "${f%.example}")"
  done
  # bootstrap.conf and site.conf both claim app.example.com: the pair is a
  # before/after, never loaded together.
  rm "$dir/sites/bootstrap.conf"

  while read -r domain; do
    mkdir -p "$dir/certs/live/$domain"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$domain" \
      -keyout "$dir/certs/live/$domain/privkey.pem" \
      -out "$dir/certs/live/$domain/fullchain.pem" 2>/dev/null
  done < <(grep -hoE 'live/[a-z0-9.-]+/fullchain' examples/*.conf.example | cut -d/ -f2 | sort -u)

  # nginx runs as a different uid in the container; make the throwaway tree readable.
  chmod -R a+rX "$dir"
}
