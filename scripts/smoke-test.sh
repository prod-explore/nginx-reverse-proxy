#!/usr/bin/env bash
# Run the real proxy and check what it does, not only that its config parses.
#
# Starts the nginx service from docker-compose.yml (same image, read-only root,
# dropped capabilities) with every site example, throwaway certificates and one
# stub backend that answers for all example container names and echoes the
# request headers it received. Then checks the behaviour the README promises:
# unknown hosts rejected, redirects, ACME webroot, security headers, client
# address not spoofable, dotfiles denied, WebSocket upgrade, login rate limit,
# and that `nginx -t && nginx -s reload` works inside the running container.
#
# Needs docker (with compose v2.24.4 or newer), openssl and curl. Used by CI.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/fixtures.sh
. scripts/fixtures.sh

image=$(sed -n 's|^[[:space:]]*image: \(nginx:[^[:space:]]*\)$|\1|p' docker-compose.yml | head -1)
: "${image:?could not read the nginx image from docker-compose.yml}"

# A compose project of its own, so the test never touches the containers or
# networks of a proxy already running on the host.
project="nrp-smoke-$$"
work=$(mktemp -d)
compose() { docker compose -p "$project" -f docker-compose.yml -f "$work/compose.yml" "$@"; }
cleanup() {
  compose down --remove-orphans --timeout 1 >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

make_fixtures "$work"
mkdir -p "$work/webroot/.well-known/acme-challenge"
echo "acme-token-ok" > "$work/webroot/.well-known/acme-challenge/token"

# The stub backend listens on every port the examples use. Its X-Powered-By
# header gives the proxy something to hide.
cat > "$work/backend.conf" <<'EOF'
server {
    listen 80;
    listen 3000;
    listen 8080;
    location / {
        add_header X-Powered-By "Express";
        return 200 "xff=[$http_x_forwarded_for] xri=[$http_x_real_ip] fwd=[$http_forwarded] proxy=[$http_proxy] upgrade=[$http_upgrade] conn=[$http_connection] proto=[$http_x_forwarded_proto]\n";
    }
}
EOF

# Same service as in production, except: sites and certificates come from the
# throwaway tree, ports go to random loopback ports (!override replaces the
# production list instead of adding to it), the container name is per run, and
# a 1 s healthcheck lets --wait return quickly.
cat > "$work/compose.yml" <<EOF
services:
  nginx:
    container_name: ${project}-nginx
    ports: !override
      - "127.0.0.1::80"
      - "127.0.0.1::443"
    volumes:
      - $work/sites:/etc/nginx/sites:ro
      - $work/certs:/etc/letsencrypt:ro
      - $work/webroot:/var/www/certbot:ro
    healthcheck:
      interval: 1s
  backend:
    image: $image
    volumes:
      - $work/backend.conf:/etc/nginx/conf.d/default.conf:ro
    networks:
      default:
        aliases: [app, stream-app, shop-api, shop-web]
EOF
chmod -R a+rX "$work"

compose up -d --wait --wait-timeout 60 nginx backend >/dev/null
http_port=$(compose port nginx 80 | cut -d: -f2)
https_port=$(compose port nginx 443 | cut -d: -f2)

passed=0
failed=0
ok()   { passed=$((passed + 1)); echo "ok   $1"; }
fail() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
# check NAME HAYSTACK NEEDLE: passes if NEEDLE occurs in HAYSTACK.
check()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else fail "$1" "expected '$3' in: $2"; fi; }
# refute NAME HAYSTACK NEEDLE: passes if NEEDLE does not occur in HAYSTACK,
# ignoring case.
refute() { if grep -qiF -- "$3" <<<"$2"; then fail "$1" "unexpected '$3' in: $2"; else ok "$1"; fi; }

# HTTP or HTTPS request to HOST, sent to the proxy whatever HOST resolves to.
http()  { local host=$1 path=$2; shift 2
          curl -sS --noproxy "*" --max-time 5 --resolve "$host:$http_port:127.0.0.1" "$@" "http://$host:$http_port$path"; }
https() { local host=$1 path=$2; shift 2
          curl -sS --noproxy "*" --max-time 5 -k --resolve "$host:$https_port:127.0.0.1" "$@" "https://$host:$https_port$path"; }
# Status code only, or curl's exit code prefixed with "curl-" when no response came.
status_of() { local code; code=$("$@" -o /dev/null -w '%{http_code}' 2>/dev/null) && echo "$code" || echo "curl-$?"; }

echo "== Unknown hosts"
check "HTTP to an unknown host gets the connection closed (444)" \
  "$(status_of http unknown.example.org /)" "curl-52"
check "TLS to an unknown host is refused without a certificate" \
  "$(status_of https unknown.example.org /)" "curl-35"

echo "== Port 80"
check "HTTP redirects to HTTPS" \
  "$(http app.example.com /path?q=1 -o /dev/null -w '%{http_code} %{redirect_url}')" \
  "301 https://app.example.com/path?q=1"
check "ACME challenge is served from the certbot webroot" \
  "$(http app.example.com /.well-known/acme-challenge/token)" "acme-token-ok"

echo "== HTTPS"
headers=$(https app.example.com / -D - -o /dev/null)
check "HTTPS reaches the backend" "$(https app.example.com /)" "proto=[https]"
check "HTTP/2 is negotiated" "$(https app.example.com / -o /dev/null -w '%{http_version}')" "2"
check "HSTS header is sent" "$headers" "strict-transport-security: max-age=31536000; includeSubDomains"
check "nosniff header is sent" "$headers" "x-content-type-options: nosniff"
check "Server header carries no version" "$headers" $'server: nginx\r'
refute "X-Powered-By from the backend is hidden" "$headers" "x-powered-by"
check "TLS 1.2 is accepted" "$(status_of https app.example.com / --tlsv1.2 --tls-max 1.2)" "200"
check "TLS 1.3 is accepted" "$(status_of https app.example.com / --tlsv1.3)" "200"
# openssl, not curl: a modern curl gives up on TLS 1.1 itself, which would prove
# nothing. SECLEVEL=0 lets the client offer it; the alert must come from nginx.
tls() { openssl s_client -connect "127.0.0.1:$https_port" -servername app.example.com \
          -cipher 'ALL:@SECLEVEL=0' "$@" </dev/null 2>&1 || true; }
check "TLS 1.1 is refused by the server" "$(tls -tls1_1)" "alert protocol version"
check "a cipher without forward secrecy is refused" "$(tls -tls1_2 -cipher 'AES128-SHA:@SECLEVEL=0')" \
  "alert handshake failure"

echo "== Client address"
echoed=$(https app.example.com / -H 'X-Forwarded-For: 203.0.113.66' -H 'X-Real-IP: 203.0.113.66' \
  -H 'Forwarded: for=203.0.113.66' -H 'Proxy: http://203.0.113.66')
refute "a forged X-Forwarded-For/X-Real-IP does not reach the backend" "$echoed" "203.0.113.66"
xff=$(sed -n 's/.*xff=\[\([^]]*\)\].*/\1/p' <<<"$echoed")
check "X-Forwarded-For is the peer address, the same as X-Real-IP" "$echoed" "xri=[$xff]"
check "the Forwarded header is dropped" "$echoed" "fwd=[]"
check "the Proxy header (httpoxy) is dropped" "$echoed" "proxy=[]"

echo "== Paths"
check "dotfiles are denied" "$(status_of https app.example.com /.git/config)" "403"
check "frontend and API are routed to their backends" \
  "$(status_of https shop.example.com /api/items) $(status_of https shop.example.com /)" "200 200"

echo "== WebSocket"
# HTTP/1.1: an HTTP/2 request cannot carry an Upgrade header at all.
check "an ordinary request is not marked as an upgrade" "$(https stream.example.com / --http1.1)" \
  "upgrade=[] conn=[]"
check "an upgrade request is passed on as one" \
  "$(https stream.example.com / --http1.1 -H 'Upgrade: websocket' -H 'Connection: Upgrade')" \
  "upgrade=[websocket] conn=[upgrade]"

echo "== Rate limiting"
codes=""
for _ in 1 2 3 4 5 6 7 8; do codes+="$(status_of https shop.example.com /api/login -X POST) "; done
check "login allows 1 + burst of 5, then answers 429" "$codes" "200 200 200 200 200 200 429 429"

echo "== Reload (the step the README runs after adding a site)"
if compose exec -T nginx sh -c 'nginx -t -q && nginx -s reload' >/dev/null 2>&1; then
  ok "nginx -t && nginx -s reload works in the read-only container"
else
  fail "nginx -t && nginx -s reload works in the read-only container"
fi
check "still serving after the reload" "$(status_of https app.example.com /)" "200"

echo
echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then
  compose logs nginx | tail -40
  exit 1
fi
