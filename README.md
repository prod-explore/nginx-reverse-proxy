# nginx-reverse-proxy

A small, hardened reverse proxy for a Docker host: **one nginx with automatic HTTPS (certbot) in front of any number of containers**, each on its own network. No generator, no labels, no control plane: a site is a plain nginx file copied from `examples/`, and CI starts the real proxy and runs 25 checks against what [is hardened](#what-is-hardened-and-why).

```
Internet ─▶ nginx :80/:443 ─┬─▶ app1_net ─▶ app1      unknown hosts: connection closed, no certificate shown
                            ├─▶ app2_net ─▶ app2      certbot renews the certificates, nginx reloads every 6 h
                            └─▶ app3_net ─▶ app3      backends never see each other, none publishes a port
```

```bash
git clone https://github.com/prod-explore/nginx-reverse-proxy.git && cd nginx-reverse-proxy
docker compose up -d        # nginx on :80/:443; every host is refused until you add a site
```

I run this on a Raspberry Pi in front of a handful of unrelated projects.

## Connecting backends

Each backend keeps its own network, and the proxy joins all of them, so two backends never see each other and none publishes a port to the host.

```bash
docker network create app1_net        # once per backend; attach the backend to it in its own compose file
cp docker-compose.override.example.yml docker-compose.override.yml   # list your networks in it
docker compose up -d
```

`docker-compose.override.yml` is gitignored; the example lists `app1_net` and `app2_net`, and `docker compose up` fails until every network it lists exists.

## Adding a site

DNS for the domain must point at the host, and ports 80 and 443 must be reachable. A site needs a certificate before its HTTPS server can load, so adding one takes two steps, both on the same file.

**1. Bootstrap, and get the certificate**

```bash
DOMAIN=app.your-domain.com       # the site's domain
cp examples/bootstrap.conf.example "sites/$DOMAIN.conf"
sed -i "s/app.example.com/$DOMAIN/g" "sites/$DOMAIN.conf"
docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload

docker compose run --rm --entrypoint certbot certbot certonly --webroot -w /var/www/certbot \
  -d "$DOMAIN" --email you@example.com --agree-tos --no-eff-email
```

**2. Replace the bootstrap with the real site**

```bash
BACKEND=app:3000                 # <container name>:<port> of the backend
cp examples/site.conf.example "sites/$DOMAIN.conf"          # overwrites the bootstrap
sed -i "s/app.example.com/$DOMAIN/g; s/app:3000/$BACKEND/g" "sites/$DOMAIN.conf"
docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload
```

Pick the example that matches the backend; the two variants use their own placeholders, so adjust the `sed` to them:

| Example | For | Placeholders |
|---|---|---|
| `examples/site.conf.example` | An ordinary web app or API | `app.example.com`, `app:3000` |
| `examples/site-streaming.conf.example` | Server-sent events, long polling, WebSockets: no buffering, long timeouts | `stream.example.com`, `stream-app:8080` |
| `examples/site-frontend-and-api.conf.example` | A frontend and an API in different containers, with a stricter limit on the login endpoint | `shop.example.com`, `shop-web:80`, `shop-api:3000` |

Certificates renew by themselves (see below). To remove a site, delete its file from `sites/`, reload nginx, and run `docker compose run --rm --entrypoint certbot certbot delete --cert-name YOUR.DOMAIN`.

## Layout

```
nginx/nginx.conf          main config: limits, logging, timeouts, resolver, WebSocket map
nginx/snippets/           shared pieces: ssl, security headers, proxy headers, timeouts, streaming
nginx/conf.d/             the catch-all default server and the health endpoint
examples/                 site files to copy into sites/
sites/                    your sites (gitignored)
certs/                    certificates and ACME webroot (gitignored, created on first start)
scripts/check.sh          runs `nginx -t` on every example in the proxy's image
scripts/smoke-test.sh     starts the proxy with the examples and checks what it does
scripts/fixtures.sh       throwaway sites and certificates, shared by the two scripts
SECURITY.md               how to report a vulnerability, and what is in scope
```

Your own sites and certificates never enter the repository: `sites/*.conf`, `certs/`, `.env` and `docker-compose.override.yml` are gitignored.

## What is hardened, and why

| Area | What | Why |
|---|---|---|
| Unknown hosts | Default server closes the connection (`444`) and refuses the TLS handshake (`ssl_reject_handshake`) | Scanners hitting the bare IP learn nothing, and no certificate (so no hostname of yours) is disclosed |
| TLS | TLS 1.2/1.3, the Mozilla "intermediate" ECDHE ciphers (DHE suites left out, so no dhparam file to manage), session tickets off | Forward secrecy; nginx never rotates the ticket key while it runs, so tickets would weaken it. No OCSP stapling: Let's Encrypt shut down OCSP in 2025 |
| Headers | HSTS (one year, `includeSubDomains`, no `preload`), `nosniff`, `Referrer-Policy`, `X-Frame-Options`, no `Server` version, no `X-Powered-By` | Cheap defence in depth. `preload` is hard to undo, so it is left to you. CSP is left to the application, which knows what it loads |
| Client address | `X-Forwarded-For` is *replaced* with the real peer address, not appended to; client-sent `Forwarded` and `Proxy` headers are dropped | A client cannot forge its address to a backend that uses `trust proxy 1` or per-IP limits; `Proxy` is the httpoxy vector |
| Abuse | Per-IP request rate (20 r/s, burst 60) and connection limits, answered with `429` | Cheap floods stop at the proxy; the connection limit is higher for streaming sites |
| Slow clients | Short header/body timeouts, bounded header buffers, `client_max_body_size` per site | Slowloris-style connection hoarding, oversized uploads |
| Resolution | Upstreams are resolved per request through Docker DNS, with a 5 s lookup timeout | A backend that restarts, or is not up yet, never stops nginx from starting or reloading |
| WebSocket | `Connection: upgrade` is sent only when the client asked for an upgrade | One location serves both WebSocket handshakes and ordinary requests, which reach the backend unchanged |
| Files | Dotfiles (`.git`, `.env`) are never served | Common scanner targets |
| Container | Read-only filesystem, `no-new-privileges`, all capabilities dropped except the four nginx needs, memory and pid limits, log rotation | A compromised worker has very little to work with |
| Certificates | certbot checks twice a day; nginx reloads every 6 h to pick up renewals | Renewal needs no human and no restart |
| Config changes | `nginx -t` before every reload (in the steps above); `check.sh` and `smoke-test.sh` in CI | A typo cannot take every site down |

nginx listens on IPv4 only inside the container: Docker forwards the host's IPv6 port to it anyway, and a `[::]` listener would stop nginx from starting on a kernel without IPv6.

### Rate limiting a login endpoint

`nginx.conf` defines a stricter `login` zone (5 requests per minute per IP) next to the general `perip` zone. `examples/site-frontend-and-api.conf.example` applies it to `/api/login` with a burst of 5: the 7th quick attempt gets `429`.

## Around the proxy

The proxy is one layer. On the host:

- Bind internal services to `127.0.0.1` or keep them off the host entirely. A port published by Docker bypasses `ufw`/`iptables` rules written for the host.
- Allow only 22, 80 and 443 from outside; consider `fail2ban` for SSH.
- If the host sits behind Cloudflare, restore the real client address (`set_real_ip_from` + `real_ip_header CF-Connecting-IP`) before relying on per-IP limits.

## Validation

```bash
scripts/check.sh          # every example through `nginx -t` in the proxy's image, plus the bootstrap alone
scripts/smoke-test.sh     # starts the proxy and a stub backend, runs 25 checks, prints "25 passed, 0 failed"
```

Both need Docker and openssl; the smoke test also needs curl and Docker Compose 2.24.4 or newer, and uses random loopback ports, so it runs next to a live proxy. The smoke test checks: unknown hosts refused on both ports, the HTTP→HTTPS redirect, the ACME webroot, HTTP/2, the security headers and hidden versions, TLS 1.2/1.3 accepted and TLS 1.1 and non-forward-secret ciphers refused, the forged-address headers, dotfiles, routing of the frontend/API example, the WebSocket upgrade, the login rate limit, and `nginx -t && nginx -s reload` inside the read-only container.

CI (`.github/workflows/ci.yml`) runs on every push to `main` and every pull request: `shellcheck`, `check.sh`, `docker compose config` for the compose file alone and with the override example, and `smoke-test.sh`. nginx 1.25.1 or newer is required (`http2 on;`); the nginx and certbot images are pinned in `docker-compose.yml` and kept current by Dependabot.

## License

[MIT](LICENSE)
