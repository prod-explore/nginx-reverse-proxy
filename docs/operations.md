# Operations

Day-to-day tasks on a running proxy. Every command runs from the repository directory on the server. `DOMAIN` and `EMAIL` are the variables from the [deployment steps](../README.md#deploy-on-a-server).

After any change to `sites/` or `nginx/`, test and reload:

```sh
scripts/reload.sh
```

It runs `nginx -t` inside the container and reloads only if the test passes; a broken file changes nothing. Reloading without the test is also safe for the running proxy, which keeps its old configuration, but the broken file stays on disk and the next container restart fails.

nginx runs with `-c "$NGINX_CONF"` (set in `docker-compose.yml`). A bare `nginx -t` inside the container tests the image's unused default configuration and proves nothing; `reload.sh` passes `-c`.

## Adding a site

A site is enabled by copying an example into `sites/` and editing the copy; `sites/*.conf` is gitignored, so a `git pull` never touches it. Every site goes through two files (steps 4 and 5 of the [deployment](../README.md#deploy-on-a-server)): first the before-certificate file, until certbot has issued the certificate, then the full site copied over it.

| Example | Use it for |
| --- | --- |
| [`site-before-certificate.conf.example`](../examples/site-before-certificate.conf.example) | step 1 of every site: only the ACME challenge, until the certificate exists |
| [`site.conf.example`](../examples/site.conf.example) | step 2: one backend |
| [`site-frontend-and-api.conf.example`](../examples/site-frontend-and-api.conf.example) | step 2: a frontend and an API in two containers, with a stricter limit on `/api/login` |
| [`site-streaming.conf.example`](../examples/site-streaming.conf.example) | step 2: WebSockets, server-sent events, long polling |

For example, a frontend and an API, once the certificate exists:

```sh
cp examples/site-frontend-and-api.conf.example "sites/$DOMAIN.conf"
```

Each example's header names the placeholders to replace in the copy (the domain and each backend's `<container name>:<port>`). Then run `scripts/reload.sh`. The API example passes `/api/...` to the API unchanged; the API must serve its routes under `/api`.

## Adding a backend network

Each backend gets its own network, and the proxy joins all of them. There are two ways to add one.

**With a short interruption.** Add the network to `docker-compose.override.yml`, under `services.nginx.networks` and as an `external: true` entry under `networks`, then:

```sh
docker compose up -d
```

Compose recreates the nginx container. Every site is unavailable for the few seconds that takes.

**Without an interruption.** Connect the running container, then add the network to `docker-compose.override.yml` as above so that it survives the next `docker compose up`:

```sh
docker network connect app2_net nginx-proxy
```

## IPv6

The repository's part is in place: the proxy's network has IPv6 (`enable_ipv6` in `docker-compose.yml`, no subnet), and every server listens on `[::]` as well as on IPv4. Docker then forwards an IPv6 connection on 80 or 443 to nginx's own IPv6 address, so nginx logs, rate-limits and forwards the client's real address. Without IPv6 on that network, Docker's userland proxy relays the connection and every IPv6 client appears as one Docker gateway address. Backend networks need no IPv6.

On the host:

1. **Docker Engine 27 or newer** (`docker version`). From 27.0, `ip6tables` is on by default and an IPv6 network created without a subnet gets a unique local `/64`. Older engines need experimental settings and an explicit subnet; upgrade instead.
2. **`ip6tables` left on.** Nothing is needed in `/etc/docker/daemon.json` unless it turns `ip6tables` off. If it does, set it back, keeping the file's other keys, and run `sudo systemctl restart docker` (this restarts every container on the host):

   ```json
   {
     "ip6tables": true
   }
   ```

   Two settings that look related are not needed: `"ipv6": true` applies only to the default `docker0` bridge, which Compose does not use, and `"userland-proxy": false` changes nothing for clients from outside, whose connections already go through `ip6tables` and never reach the userland proxy.
3. **A public IPv6 address, open on 80 and 443.** `ip -6 addr show scope global` lists the host's addresses; use the one not marked `temporary`. Home routers usually drop unsolicited inbound IPv6: allow TCP 80 and 443 to that address on the router, and in the host's firewall if it runs one.
4. **An AAAA record** for every name, next to its A record. Let's Encrypt validates over IPv6 when an AAAA record exists, so add it only once step 3 works, or issuing and renewal can fail.

A proxy that already ran before IPv6 was enabled keeps its IPv4-only network until the network is recreated. That stops every site for a few seconds:

```sh
docker compose down
docker compose up -d
docker network inspect proxy_default --format '{{.EnableIPv6}}'    # true
```

To verify, open a site from a device outside your network over IPv6 only, such as a phone on mobile data with Wi-Fi off, then look at `docker compose logs nginx`: the request must show the phone's public IPv6 address, not an address of the Docker network.

## Certificates

**Several names on one certificate.** Pass each name with `-d`. certbot stores the certificate under the first name, so the paths in the site file stay `live/$DOMAIN/...`; list every name in each `server_name` line of the site file, and in the before-certificate file before issuing.

```sh
docker compose run --rm --entrypoint certbot certbot certonly --webroot -w /var/www/certbot \
  -d "$DOMAIN" -d "www.$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email
```

**A trial run first.** Let's Encrypt limits failed validations per hour. `--dry-run` validates against its staging environment and saves nothing:

```sh
docker compose run --rm --entrypoint certbot certbot certonly --webroot -w /var/www/certbot \
  -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email --dry-run
```

**Renewal** happens in the `certbot` container, which runs `certbot renew` every 12 hours. nginx reloads every 6 hours and then serves the renewed files. To list the certificates and test renewal now:

```sh
docker compose exec certbot certbot certificates
docker compose exec certbot certbot renew --dry-run
```

## Removing a site

Remove the site file first: a site file that names a deleted certificate stops nginx from starting.

```sh
rm "sites/$DOMAIN.conf"
scripts/reload.sh
docker compose exec certbot certbot delete --cert-name "$DOMAIN"
```

After the reload the name falls through to the catch-all server, which refuses it like any unknown host.

## Changing the configuration

| What changed | What to run |
| --- | --- |
| `sites/*.conf`, anything under `nginx/` | `scripts/reload.sh` |
| `docker-compose.yml`, `docker-compose.override.yml` | `docker compose up -d` |

`nginx/` and `sites/` are mounted as directories, never as single files. `git pull` and many editors replace a file rather than write into it; a bind-mounted file would keep the container on the old copy until it is recreated, while a mounted directory shows the new file on the next reload.

## Updates

Dependabot opens a pull request each week when a pinned image or GitHub Action has an update, and CI tests it. nginx updates stay on its stable branch; moving to the next stable branch means changing the tag in `docker-compose.yml` by hand. After merging, on the server:

```sh
git pull
docker compose up -d
scripts/reload.sh
```

`docker compose up -d` pulls the new images and recreates only the containers whose image or settings changed. A change under `nginx/` alone recreates nothing, so `reload.sh` applies it.

## Logs and health

```sh
docker compose logs -f nginx
docker compose logs certbot
docker compose ps
```

nginx writes one line per request: client address, host, request line, status, bytes sent, total time (`rt`), backend time (`urt`) and user agent.

```text
2001:db8:4:1::7 shop2.example.com "GET /api/x HTTP/2.0" 200 28 rt=0.001 urt=0.001 "curl/8.5.0"
```

The health check requests `http://127.0.0.1:8081/healthz` inside the container every 30 seconds. `docker compose ps` shows the result; Docker does not act on it.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `curl: (52) Empty reply from server` on port 80, or a TLS handshake failure (`unrecognized name`) on 443 | The catch-all server answered: no site file has this name in `server_name`, or it was not reloaded. Note that `nginx -s reload` returns before the new workers are up; a request sent in the same instant can still meet the old configuration. |
| `nginx -t`: `cannot load certificate "/etc/letsencrypt/live/..."` | The site file names a certificate that does not exist yet. Use a copy of `site-before-certificate.conf.example` until certbot has issued it. |
| certbot: the challenge fails | The DNS record does not point to this host, port 80 is closed, or the before-certificate file for this name is not loaded. |
| `502` or `504` from one site | The backend is down, listens on another port, or shares no network with `nginx-proxy`. `docker compose exec nginx wget -q -O - http://<container>:<port>/` tests the path from the proxy. |
| The container restarts in a loop | nginx cannot load its configuration. `docker compose logs nginx` names the file and line. |
