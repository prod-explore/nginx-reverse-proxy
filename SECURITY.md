# Security policy

## Supported version

Only `main` is supported. There are no releases; fixes land on `main`.

## Reporting a vulnerability

Please report privately through GitHub: **Security → Report a vulnerability** on this repository (private vulnerability reporting). Do not open a public issue for a vulnerability.

Include the file and lines involved, what an attacker can do, and how to reproduce it (a request, a site file, or a failing check in `scripts/smoke-test.sh`). Expect a first answer within a week.

## Scope

In scope: the configuration in this repository and what it claims in the README.

- `nginx/` (TLS settings, security headers, proxy headers, limits, the default server)
- `examples/` as shipped
- `docker-compose.yml` (container hardening, certbot renewal)
- `scripts/`

For example: a way to reach a backend through a host that is not configured, to forge the client address a backend sees, to get a certificate or hostname out of the default server, to bypass the rate limits, or to make the proxy serve files it should not.

Out of scope: vulnerabilities in nginx, certbot, OpenSSL or Docker themselves (report those upstream; an outdated pinned image is welcome as an ordinary issue), your own site files and backends, and the host around the proxy.
