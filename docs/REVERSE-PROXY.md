# Reverse proxy

The installer does **not** install or manage a reverse proxy. TLS termination,
certificates and routing are the host's responsibility, to be handled however
that host already does it.

## Moving to a real domain

The recommended first step, once you have a hostname and a proxy in mind, is:

```bash
sudo sentinel-ops domain set app.example.com
```

This does everything a domain move needs in one config change plus a
restart - **no reinstall, no rebuild, no data loss**:

- sets `SUPABASE_PUBLIC_URL`, `API_EXTERNAL_URL` and `SITE_URL` to
  `https://app.example.com`
- adds it to `ADDITIONAL_REDIRECT_URLS` so auth redirects keep working
- flips `APP_BIND` back to `127.0.0.1` (a domain implies a proxy in front, so
  direct exposure is no longer wanted - see
  [DECISIONS.md #7](DECISIONS.md#7-no-reverse-proxy-is-installed))
- persists both to `config/installer.env` and `supabase/.env`, then restarts
  Kong, Auth and the frontend so they pick up the new URLs

Run `sentinel-ops domain status` at any time to see which mode (loopback, LAN
or domain) is currently active. This replaces hand-editing
`config/installer.env` - do that only for settings `domain set` does not
cover.

What it does **not** do is register DNS or run a proxy: point `app.example.com`
at this server yourself, and see the worked configurations below for the proxy
that terminates TLS and forwards to the two upstreams `domain set` just
printed.

What the installer guarantees regardless of mode is a stable pair of
upstreams to point at.

## The two upstreams

```bash
sentinel-ops status     # prints both under "URLs"
```

| Upstream | Default | What it serves |
|---|---|---|
| Frontend | `127.0.0.1:41820` | The React application (Node running the Nitro SSR server) |
| Supabase API | `127.0.0.1:8000` | Kong — REST, Auth, Storage, Realtime, Edge Functions, Studio |

A fresh install binds both to every interface (`APP_BIND=0.0.0.0`) so the LAN
can reach them with zero manual config - see [DECISIONS.md
#7](DECISIONS.md#7-no-reverse-proxy-is-installed) and `sentinel-ops network
status`. Once you put a proxy in front with `sentinel-ops domain set`,
`APP_BIND` goes back to **loopback only**: the proxy on this host reaches
them, the public internet does not.

```
        Internet
           │
           ▼
   your reverse proxy          ← you manage this
      ┌────┴─────┐
      ▼          ▼
 127.0.0.1:41820  127.0.0.1:8000
   frontend        Supabase Kong
```

### If the proxy runs elsewhere

Set `APP_BIND=0.0.0.0` in `config/installer.env` and re-run
`sentinel-ops update app`, or use `sentinel-ops network enable`, which does
the same bind change and also opens the frontend port in `ufw`/`firewalld` if
one is active. If no firewall is enforcing anything on this host, **firewall
the port yourself** — nothing else will.

### If the proxy runs in Docker

The frontend container joins the Supabase Docker network, so a proxy container
on that same network can route to it by name instead of through the host:

```bash
docker network connect "$(docker inspect -f \
  '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' supabase-db)" my-proxy
```

Then use `sentinel-ops-frontend:41820` and `kong:8000` as the upstreams.

---

## Example configurations

These are references, not managed files. Adapt them to your setup.

### nginx

```nginx
server {
    listen 443 ssl http2;
    server_name app.sentinelops.com;

    ssl_certificate     /etc/letsencrypt/live/app.sentinelops.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/app.sentinelops.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:41820;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 443 ssl http2;
    server_name supabase.sentinelops.com;

    ssl_certificate     /etc/letsencrypt/live/supabase.sentinelops.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/supabase.sentinelops.com/privkey.pem;

    # Storage uploads are large; the 1 MB default will reject them.
    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Realtime uses WebSockets.
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }
}
```

### Caddy

```caddyfile
app.sentinelops.com {
    reverse_proxy 127.0.0.1:41820
    encode gzip zstd
}

supabase.sentinelops.com {
    reverse_proxy 127.0.0.1:8000
    encode gzip zstd
    request_body {
        max_size 50MB
    }
}
```

### Traefik (dynamic file provider)

```yaml
http:
  routers:
    sentinel-app:
      rule: "Host(`app.sentinelops.com`)"
      service: sentinel-app
      tls:
        certResolver: letsencrypt
    sentinel-supabase:
      rule: "Host(`supabase.sentinelops.com`)"
      service: sentinel-supabase
      tls:
        certResolver: letsencrypt
  services:
    sentinel-app:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:41820"
    sentinel-supabase:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8000"
```

---

## Things that will bite you

**WebSockets.** Supabase Realtime needs `Upgrade`/`Connection` headers and a
long read timeout. Without them Realtime silently fails to connect while
everything else looks fine.

**Upload size.** nginx defaults to a 1 MB body limit, which rejects Storage
uploads with a confusing 413.

**The URLs come from runtime env vars, not the bundle.** The app reads
`SUPABASE_URL`/`SUPABASE_PUBLIC_URL` from `process.env` at runtime via
`/runtime-config.js`, so the domains must match `SUPABASE_PUBLIC_URL` in
`config/installer.env`. Changing a domain only needs the container restarted
with the new value (`sentinel-ops update app` does this), not a rebuild — but
it still needs the container, not just the proxy, reloaded.

**Do not expose Logflare.** Its `/dashboard` has no authentication of its own.
Port 4000 is not published by default — keep it that way.

**Studio.** Reached through the Supabase hostname and protected by
`DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` (see `sentinel-ops credentials`).
That is HTTP basic auth, so consider restricting it by IP at the proxy too.
