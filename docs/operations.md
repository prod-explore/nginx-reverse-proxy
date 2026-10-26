# Operations

Day-to-day tasks on a running proxy. Every command runs from the repository directory on the server. `DOMAIN`, `BACKEND` and `EMAIL` are the variables from the [deployment steps](../README.md#deploy-on-a-server).

After any change to `sites/`, `nginx/snippets/` or `nginx/conf.d/`, test and reload:

```sh
docker compose exec nginx sh -c 'nginx -t && nginx -s reload'
```

`nginx -t` refuses a broken file and nothing changes. Reloading without it is also safe for the running proxy, which keeps its old configuration, but the broken file stays on disk and the next container restart fails.

## Adding a site

Every site starts with the bootstrap file and a certificate (steps 4 and 5 of the [deployment](../README.md#deploy-on-a-server)). Only the file that replaces the bootstrap file differs.

| Example | Use it for |
| --- | --- |
| [`site.conf.example`](../examples/site.conf.example) | one backend |
| [`site-frontend-and-api.conf.example`](../examples/site-frontend-and-api.conf.example) | a frontend and an API in two containers, with a stricter limit on `/api/login` |
| [`site-streaming.conf.example`](../examples/site-streaming.conf.example) | WebSockets, server-sent events, long polling |

A frontend and an API:

```sh
WEB=shop-web:80       # <container name>:<port> of the frontend
API=shop-api:3000     # <container name>:<port> of the API
sed -e "s/shop.example.com/$DOMAIN/g" -e "s/shop-web:80/$WEB/" -e "s/shop-api:3000/$API/" \
  examples/site-frontend-and-api.conf.example > "sites/$DOMAIN.conf"
```

A streaming backend:

```sh
sed -e "s/stream.example.com/$DOMAIN/g" -e "s/stream-app:8080/$BACKEND/" \
  examples/site-streaming.conf.example > "sites/$DOMAIN.conf"
```

Then test and reload. The API example passes `/api/...` to the API unchanged; the API must serve its routes under `/api`.

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

## Certificates

**Several names on one certificate.** Pass each name with `-d`. certbot stores the certificate under the first name, so the paths in the site file stay `live/$DOMAIN/...`; list every name in each `server_name` line of the site file, and in the bootstrap file before issuing.

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
docker compose exec nginx sh -c 'nginx -t && nginx -s reload'
docker compose exec certbot certbot delete --cert-name "$DOMAIN"
```

After the reload the name falls through to the catch-all server, which refuses it like any unknown host.

## Changing the configuration

| What changed | What to run |
| --- | --- |
| `sites/*.conf`, `nginx/snippets/`, `nginx/conf.d/` | `docker compose exec nginx sh -c 'nginx -t && nginx -s reload'` |
| `nginx/nginx.conf` | `docker compose restart nginx` |
| `docker-compose.yml`, `docker-compose.override.yml` | `docker compose up -d` |

`nginx/nginx.conf` is the one file mounted on its own. `git pull` and many editors replace a file instead of writing into it, and the container keeps the old copy until it restarts; a reload is not enough. Check before restarting, so that a mistake does not take every site down:

```sh
docker compose run --rm --no-deps nginx nginx -t
```

## Updates

Dependabot opens a pull request each week when a pinned image or GitHub Action has an update, and CI tests it. nginx updates stay on its stable branch; moving to the next stable branch means changing the tag in `docker-compose.yml` by hand. After merging, on the server:

```sh
git pull
docker compose up -d
```

`docker compose up -d` pulls the new images and recreates only the containers whose image or settings changed.

## Logs and health

```sh
docker compose logs -f nginx
docker compose logs certbot
docker compose ps
```

nginx writes one line per request: client address, host, request line, status, bytes sent, total time (`rt`), backend time (`urt`) and user agent.

```text
172.20.0.1 shop2.example.com "GET /api/x HTTP/2.0" 200 28 rt=0.001 urt=0.001 "curl/8.5.0"
```

The health check requests `http://127.0.0.1:8081/healthz` inside the container every 30 seconds. `docker compose ps` shows the result; Docker does not act on it.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `curl: (52) Empty reply from server` on port 80, or a TLS handshake failure (`unrecognized name`) on 443 | The catch-all server answered: no site file has this name in `server_name`, or it was not reloaded. Note that `nginx -s reload` returns before the new workers are up; a request sent in the same instant can still meet the old configuration. |
| `nginx -t`: `cannot load certificate "/etc/letsencrypt/live/..."` | The site file names a certificate that does not exist yet. Use the bootstrap file until certbot has issued it. |
| certbot: the challenge fails | The DNS record does not point to this host, port 80 is closed, or the bootstrap file for this name is not loaded. |
| `502` or `504` from one site | The backend is down, listens on another port, or shares no network with `nginx-proxy`. `docker compose exec nginx wget -q -O - http://<container>:<port>/` tests the path from the proxy. |
| The container restarts in a loop | nginx cannot load its configuration. `docker compose logs nginx` names the file and line. |
