# Security model

What the proxy defends against, where each defence lives, and what it leaves to others. To report a vulnerability, see [SECURITY.md](../SECURITY.md).

## Assumptions

- The proxy is the only hop between clients and backends: no CDN or load balancer in front of it.
- The host is maintained separately: SSH, firewall, Docker daemon and kernel updates are outside this repository.
- Whoever can write to `sites/`, `certs/` or the repository directory on the server controls the proxy.
- Each backend is a container on its own Docker network and publishes no ports on the host.

## Exposure

Only the nginx container publishes ports: 80 and 443 on all host addresses, IPv4 and IPv6. The certbot container publishes none. The health endpoint listens on `127.0.0.1:8081` inside the nginx container, so neither the internet nor other containers reach it. Neither container mounts the Docker socket.

## Threats and defences

"Smoke test" marks the defences that [`scripts/smoke-test.sh`](../scripts/smoke-test.sh) checks against a running proxy in CI.

| Threat | Defence | Where | Smoke test |
| --- | --- | --- | --- |
| Discovering the hosted sites by scanning the IP address | Unknown hosts: connection closed on 80 (`444`), TLS handshake refused on 443 without a certificate | [`conf.d/00-default.conf`](../nginx/conf.d/00-default.conf) | yes |
| Plain-HTTP access, SSL stripping | Redirect to HTTPS; HSTS for one year | site examples, [`security-headers.conf`](../nginx/snippets/security-headers.conf) | yes |
| Protocol downgrade, weak ciphers | TLS 1.2 and 1.3 only; ECDHE with AEAD ciphers only | [`ssl.conf`](../nginx/snippets/ssl.conf) | yes: TLS 1.1 and a cipher without forward secrecy are refused |
| Forging the client address a backend sees | `X-Forwarded-For` and `X-Real-IP` set from the TCP peer; client-sent `Forwarded` emptied | [`proxy-headers.conf`](../nginx/snippets/proxy-headers.conf) | yes |
| httpoxy (a `Proxy` request header that CGI-style backends turn into `HTTP_PROXY`) | `Proxy` header emptied | `proxy-headers.conf` | yes |
| Fingerprinting | No nginx version; the backend's `X-Powered-By` hidden | [`nginx.conf`](../nginx/nginx.conf), `proxy-headers.conf` | yes |
| Reading `.git`, `.env` and other dotfiles a backend might serve | Any path segment starting with a dot, except `.well-known`, gets `403` | site examples | yes |
| MIME sniffing, clickjacking, referrer leaks | `nosniff`, `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy` | `security-headers.conf` | `nosniff` only |
| Password guessing on a login endpoint | 5 requests per minute per address, burst of 5, then `429` | `nginx.conf` zone `login`, applied in [`site-frontend-and-api.conf.example`](../examples/site-frontend-and-api.conf.example) | yes |
| Request floods from one address | 20 requests/s per address (burst 60), 50 concurrent connections per address | `nginx.conf` zones `perip`, `connperip`, applied per location | no |
| Slow clients holding connections (slowloris) | 10 s for headers, 15 s between body reads, 30 s between response writes, bounded header buffers | `nginx.conf` | no |
| Oversized uploads | 10 MB body limit by default | `nginx.conf`, site examples | no |
| One compromised backend reaching another | Separate Docker network per backend; only the proxy joins them | [`docker-compose.override.example.yml`](../docker-compose.override.example.yml) | no |
| A compromised nginx worker taking over the container or host | Read-only root, `tmpfs` scratch space, all capabilities dropped except `NET_BIND_SERVICE`, `CHOWN`, `SETUID`, `SETGID`; `no-new-privileges`; 256 MB memory, 256 processes | [`docker-compose.yml`](../docker-compose.yml) | the reload check runs in this container |
| Private keys leaking through the repository | `certs/` is gitignored; nginx mounts it read-only | [`.gitignore`](../.gitignore), `docker-compose.yml` | no |

## TLS details

Mozilla's "intermediate" profile, without its DHE suites, so there is no `dhparam` file to generate. The client chooses the cipher (`ssl_prefer_server_ciphers off`). Session resumption uses a shared server-side cache; session tickets are off. There is no OCSP stapling: Let's Encrypt certificates name no OCSP responder and publish revocation through CRLs. HSTS has no `preload`: a preload-list entry takes months to undo, and that is the owner's decision.

## What the proxy does not do

- **Content-Security-Policy.** It depends on what the application loads, so the application sets it.
- **Authentication, a web application firewall, bot detection.** Requests that pass the limits reach the backend as they are.
- **Volumetric DDoS protection.** Per-address limits stop one noisy client, not a distributed flood that saturates the link.
- **Recovering client addresses behind another proxy.** Behind a CDN, nginx sees the CDN's addresses; the per-address limits and `X-Forwarded-For` then apply to the CDN. There is no `real_ip` configuration.
- **Hardening of the certbot container.** It runs with a writable root filesystem and Docker's default capabilities. It publishes no ports and talks only to Let's Encrypt.

## Backend checklist

- Trust exactly one proxy hop for `X-Forwarded-For` (in Express: `app.set('trust proxy', 1)`).
- Set your own `Content-Security-Policy`.
- Do not publish ports on the host; join only your own network.
- If a page reflects user input next to a secret, turn gzip off for it in the site file (BREACH).
