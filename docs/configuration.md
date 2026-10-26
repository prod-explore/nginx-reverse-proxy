# Configuration reference

How the nginx configuration is put together, the defaults every site inherits, and the rules for writing a site file. The files themselves are commented; this page is the overview.

## How the files are loaded

The repository's `nginx/` directory is mounted at `/etc/nginx/proxy`, `sites/` at `/etc/nginx/sites`, and nginx starts with `-c /etc/nginx/proxy/nginx.conf` (`NGINX_CONF` in `docker-compose.yml`). Relative `include` paths, such as `snippets/proxy-headers.conf` in a site file, resolve against `/etc/nginx/proxy`. The image's own `/etc/nginx/nginx.conf` and `conf.d/` are not used.

[`nginx/nginx.conf`](../nginx/nginx.conf) is the only top-level file. At `http` level it includes, in this order:

1. `/etc/nginx/mime.types` from the image
2. [`snippets/ssl.conf`](../nginx/snippets/ssl.conf): TLS for every server
3. [`conf.d/*.conf`](../nginx/conf.d): the catch-all servers and the health endpoint
4. `/etc/nginx/sites/*.conf`: your sites

Both directories are mounted read-only, and as directories, so that a file replaced by `git pull` or an editor is picked up by the next reload. `sites/*.conf`, `certs/`, `.env` and `docker-compose.override.yml` are gitignored, so a `git pull` never touches them.

## Defaults

Set once in `nginx.conf`; a site can override most of them per `server` or `location`.

| Setting | Value | Effect |
| --- | --- | --- |
| `worker_connections` | 4096 | per worker process |
| `worker_rlimit_nofile` | 8192 | a proxied request holds two descriptors |
| `keepalive_timeout` | 30s | |
| `client_header_timeout` | 10s | a slow client cannot hold a connection open for long |
| `client_body_timeout` | 15s | same |
| `send_timeout` | 30s | same |
| `large_client_header_buffers` | 4 16k | bounded header size |
| `client_max_body_size` | 10m | raise per site where uploads are expected |
| `server_tokens` | off | no version in `Server` or error pages |
| `gzip` | on, level 5, from 1024 bytes | text, CSS, JavaScript, JSON, XML, SVG, and always `text/html` |
| `resolver` | `127.0.0.11 valid=30s ipv6=off` | Docker's embedded DNS, answers cached 30 s |
| `resolver_timeout` | 5s | a hanging lookup fails the request instead of waiting 30 s |

Access logs go to stdout and errors to stderr, so `docker logs` and `docker compose logs` show both. The log line is described in [operations](operations.md#logs-and-health).

## Rate and connection limits

`nginx.conf` declares the zones; nothing is limited until a location applies them. Both limits answer `429` instead of nginx's default `503`.

| Zone | Key | Rate | Applied in the examples as |
| --- | --- | --- | --- |
| `perip` | client | 20 requests/s | `limit_req zone=perip burst=60 nodelay` |
| `login` | client | 5 requests/min | `limit_req zone=login burst=5 nodelay` on `/api/login` |
| `connperip` | client | concurrent connections (with HTTP/2, concurrent requests) | `limit_conn connperip 50` (200 for streaming) |

With `nodelay`, a burst is answered at once and the next request over the limit gets `429`. On `/api/login` that is six requests in a row, then `429` until the rate frees a slot.

The key is `$limit_key`, built from the TCP peer: the IPv4 address, or for IPv6 the `/64` the address belongs to. An IPv6 client, a phone on mobile data for one, usually holds a whole `/64` and can switch addresses within it, so a per-address key would let it multiply every limit. nginx sees the real IPv6 address because the proxy's network has IPv6 (see [IPv6](operations.md#ipv6)). See the [known limits](../README.md#known-limits) for what that means behind a CDN.

## Snippets

| Snippet | Include in | What it does |
| --- | --- | --- |
| [`acme-challenge.conf`](../nginx/snippets/acme-challenge.conf) | the port 80 `server` of each site | serves `/.well-known/acme-challenge/` from the certbot webroot; `^~` keeps the site's regex locations (the dotfile rule) from taking these requests |
| [`security-headers.conf`](../nginx/snippets/security-headers.conf) | the port 443 `server`, **never a `location`** | HSTS (one year, `includeSubDomains`, no `preload`), `nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `X-Frame-Options: SAMEORIGIN` |
| [`proxy-headers.conf`](../nginx/snippets/proxy-headers.conf) | every proxied `location` | HTTP/1.1 upstream, `Host`, `X-Real-IP`, `X-Forwarded-For/-Proto/-Host` from the connection, empty `Forwarded` and `Proxy`, WebSocket upgrade headers, hides `X-Powered-By` |
| [`proxy-timeouts.conf`](../nginx/snippets/proxy-timeouts.conf) | ordinary proxied `location`s | connect 5 s, send and read 60 s |
| [`proxy-streaming.conf`](../nginx/snippets/proxy-streaming.conf) | streaming `location`s, **instead of** `proxy-timeouts.conf` | connect 5 s, send and read 1 h, no buffering, no cache, no gzip |
| [`ssl.conf`](../nginx/snippets/ssl.conf) | nowhere; `nginx.conf` includes it at `http` level | protocols, ciphers, session cache |

Two rules to keep:

- An `add_header` in a `location` discards every `add_header` inherited from the `server`. If a location needs its own header, it must include `security-headers.conf` again.
- `proxy-timeouts.conf` and `proxy-streaming.conf` set the same directives. Including both in one location makes `nginx -t` fail with a duplicate directive.

## Writing a site file

Start from one of the [examples](../examples). Each has:

- a port 80 `server` with the ACME snippet and a redirect to HTTPS;
- a port 443 `server` with `http2 on`, the certificate paths, the security headers, a body size limit and a rule that denies any path segment starting with a dot except `.well-known`;
- one `location` per backend.

A backend is always passed through a variable:

```nginx
location / {
    set $upstream http://app:3000;
    proxy_pass $upstream;
    include snippets/proxy-headers.conf;
    include snippets/proxy-timeouts.conf;
    limit_req  zone=perip burst=60 nodelay;
    limit_conn connperip 50;
}
```

With a literal `proxy_pass http://app:3000;` nginx resolves the name once at startup and refuses to start if the backend container does not exist. With a variable, it resolves the name per request through Docker's DNS. Two consequences:

- The request URI goes to the backend unchanged. A path after the variable does not strip the location prefix as it would after a literal address: `proxy_pass $upstream/;` sends `/` for every request. To strip a prefix, use `rewrite`.
- There is no `upstream` block, so no keepalive pool: every request opens a new connection to the backend.

Per site, consider:

- `client_max_body_size` in the 443 `server` or a `location`, where uploads are larger than 10 MB;
- `gzip off;` for `text/html` pages that reflect user input next to a secret such as a CSRF token (BREACH);
- whether `includeSubDomains` in HSTS is right for the name, before the first deployment.
