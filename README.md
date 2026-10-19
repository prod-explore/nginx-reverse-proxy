# nginx-reverse-proxy

A small, hardened reverse proxy for a Docker host: **one nginx with automatic HTTPS in front of any number of containers**, each on its own network. Sites are plain nginx files copied from examples; the whole configuration is validated in CI with the same nginx image it runs on.

```
Internet ─▶ nginx :80/:443 ─┬─▶ app1_net ─▶ app1
                            ├─▶ app2_net ─▶ app2
                            └─▶ app3_net ─▶ app3          certbot renews the certificates
```

I run this on a Raspberry Pi in front of a handful of unrelated projects.

## Quick start

```bash
cp .env.example .env                                                  # nothing secret, but yours
cp docker-compose.override.example.yml docker-compose.override.yml    # list your backends' networks
docker compose up -d
```

`docker-compose.override.yml` is where the proxy joins the networks of your backends. Each backend keeps its own network (`docker network create app1_net`, then attach the backend to it in its own compose file); the proxy joins all of them, so two backends never see each other and none publishes a port to the host.

## Adding a site

DNS for the domain must point at the host, and ports 80 and 443 must be reachable. Replace `app.example.com` and `app:3000` (container name and port of the backend) below. A site needs a certificate before its HTTPS block can load, so adding one takes two steps.

**1. Bootstrap, and get the certificate**

```bash
cp examples/bootstrap.conf.example sites/app.example.com.conf
sed -i 's/app.example.com/YOUR.DOMAIN/g' sites/app.example.com.conf
docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload

docker compose run --rm --entrypoint certbot certbot certonly --webroot -w /var/www/certbot \
  -d YOUR.DOMAIN --email you@example.com --agree-tos --no-eff-email
```

**2. Replace the bootstrap with the real site**

```bash
cp examples/site.conf.example sites/YOUR.DOMAIN.conf
sed -i 's/app.example.com/YOUR.DOMAIN/g; s/app:3000/YOUR-CONTAINER:PORT/g' sites/YOUR.DOMAIN.conf
docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload
```

Pick the example that matches the backend:

| Example | For |
|---|---|
| `examples/site.conf.example` | An ordinary web app or API |
| `examples/site-streaming.conf.example` | Server-sent events, long polling, WebSockets: no buffering, long timeouts |
| `examples/site-frontend-and-api.conf.example` | A frontend and an API in different containers, with a stricter limit on the login endpoint |

Certificates renew by themselves (see below). To remove a site, delete its file from `sites/`, reload nginx, and `docker compose run --rm --entrypoint certbot certbot delete --cert-name YOUR.DOMAIN`.

## Layout

```
nginx/nginx.conf          main config: limits, logging, timeouts, resolver, WebSocket map
nginx/snippets/           shared pieces: ssl, security headers, proxy headers, timeouts, streaming
nginx/conf.d/             the catch-all default server and the health endpoint
examples/                 vhost examples to copy into sites/
sites/                    your vhosts (gitignored)
certs/                    certificates and ACME webroot (gitignored)
scripts/check.sh          validates the whole configuration
```

Your own sites, certificates and `.env` never enter the repository: `sites/*.conf`, `certs/`, `.env` and `docker-compose.override.yml` are gitignored.

## What is hardened, and why

| Area | What | Why |
|---|---|---|
| Unknown hosts | Default server closes the connection (`444`) and refuses the TLS handshake (`ssl_reject_handshake`) | Scanners hitting the bare IP learn nothing, and no certificate (so no hostname of yours) is disclosed |
| TLS | TLS 1.2/1.3, Mozilla "intermediate" ciphers, session tickets off, OCSP stapling | Forward secrecy; ticket keys are not rotated by nginx, so tickets would undo it |
| Headers | HSTS, `nosniff`, `Referrer-Policy`, `X-Frame-Options`, no `Server` version, no `X-Powered-By` | Cheap defence in depth. CSP is left to the application, which knows what it loads |
| Client address | `X-Forwarded-For` is *replaced* with the real peer address, not appended to | A client cannot forge its address to a backend that uses `trust proxy 1` or per-IP limits |
| Abuse | Per-IP request rate (20 r/s, burst 60) and connection limits, answered with `429` | Cheap floods stop at the proxy; limits are higher for streaming sites |
| Slow clients | Short header/body timeouts, bounded header buffers, `client_max_body_size` per site | Slowloris-style connection hoarding, oversized uploads |
| Resolution | Upstreams are resolved per request through Docker DNS | A backend that restarts, or is not up yet, never stops nginx from starting or reloading |
| WebSocket | `Connection: upgrade` is sent only when the client asked for an upgrade | Keeps upstream connections reusable for ordinary requests |
| Files | Dotfiles (`.git`, `.env`) are never served | Common scanner targets |
| Container | Read-only filesystem, `no-new-privileges`, all capabilities dropped except the four nginx needs, memory and pid limits, log rotation | A compromised worker has very little to work with |
| Certificates | certbot checks twice a day; nginx reloads every 6 h to pick up renewals | Renewal needs no human and no restart |
| Config changes | `nginx -t` before every reload (in the steps above), and `scripts/check.sh` in CI | A typo cannot take every site down |

### Rate limiting a login endpoint

`nginx.conf` defines a stricter `login` zone (5 requests per minute per IP) next to the general `perip` zone. `examples/site-frontend-and-api.conf.example` shows it applied to a login route.

## Around the proxy

The proxy is one layer. On the host:

- Bind internal services to `127.0.0.1` or keep them off the host entirely. A port published by Docker bypasses `ufw`/`iptables` rules written for the host.
- Allow only 22, 80 and 443 from outside; consider `fail2ban` for SSH.
- If the host sits behind Cloudflare, restore the real client address (`set_real_ip_from` + `real_ip_header CF-Connecting-IP`) before relying on per-IP limits.

## Validation

```bash
scripts/check.sh      # copies the examples, makes throwaway certificates, runs `nginx -t` in the proxy's image
```

CI runs it on every push (and `shellcheck`), plus `docker compose config` for the compose files. nginx 1.25.1 or newer is required (`http2 on;`); the image is pinned in `docker-compose.yml`.

## License

MIT
