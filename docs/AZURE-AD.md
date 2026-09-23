# Azure AD (Microsoft Entra ID) Sign-In

Adds Microsoft/Entra ID as a Supabase Auth sign-in provider. Off by default.

```
Register an app in Entra ID → prompt at install (or `sentinel-ops azure enable`)
  → write .env → wire docker-compose.yml → restart auth
```

## Why this needs more than an `.env` change

Upstream's own `.env.example` ships the Azure variables **commented out**, with
a comment saying so: *"You must ALSO uncomment the matching GOTRUE_EXTERNAL_*
lines in docker-compose.yml."* Setting `AZURE_ENABLED=true` in `.env` alone does
nothing — Compose never passes an unreferenced `.env` variable into a
container. `azure_patch_compose()` (`lib/azure.sh`) is the one place this
installer edits vendored deployment scaffolding rather than only `.env`, for
exactly that reason: uncommenting

```
GOTRUE_EXTERNAL_AZURE_ENABLED: ${AZURE_ENABLED}
GOTRUE_EXTERNAL_AZURE_CLIENT_ID: ${AZURE_CLIENT_ID}
GOTRUE_EXTERNAL_AZURE_SECRET: ${AZURE_SECRET}
GOTRUE_EXTERNAL_AZURE_REDIRECT_URI: ${API_EXTERNAL_URL}/auth/v1/callback
```

in the `auth` service's `environment:` block, and inserting one line upstream
does not ship at all:

```
GOTRUE_EXTERNAL_AZURE_URL: ${AZURE_URL:-}
```

`GOTRUE_EXTERNAL_AZURE_URL` is how `supabase/auth` (gotrue) points at a specific
tenant instead of Microsoft's multi-tenant `common` endpoint — the field exists
in gotrue's provider configuration for every OIDC-style provider, upstream's
compose file simply never wires it for Azure. Without it, sign-in defaults to
`login.microsoftonline.com/common`, which still works but does not restrict who
can attempt to sign in to your own directory.

Upstream also ships the `REDIRECT_URI` line above as `${API_EXTERNAL_URL}/callback`
— a bare `/callback` at the Kong root, which has no route once traffic reaches
the gateway (Kong only maps `/auth/v1/callback`, with `strip_path: true`,
through to gotrue's own `/callback` handler). `azure_patch_compose()` rewrites
the path to `/auth/v1/callback` as part of uncommenting it, so the value the
running container actually uses matches what's registered with Azure. The same
path is what `_azure_redirect_uri()` prints to the operator to register in
Entra ID before enabling.

The patch is idempotent (a line already uncommented, or a `GOTRUE_EXTERNAL_AZURE_URL`
line already present, is left alone) and re-applied automatically after every
`sentinel-ops update supabase`, because that command re-syncs `docker-compose.yml`
from upstream — the same reason `supabase_apply_config` and
`logflare_configure_supabase` are re-applied there too. `.env` itself is
preserved across updates, so the values survive on their own; only the compose
wiring needs redoing.

## Variables

In `supabase/.env`, written by `azure_apply_config()`:

| Variable | Purpose |
|---|---|
| `AZURE_ENABLED` | `true`/`false` |
| `AZURE_CLIENT_ID` | Application (client) ID from the Entra ID app registration. Not secret. |
| `AZURE_SECRET` | The client secret. **Entered by the operator, never generated.** |
| `AZURE_URL` | `https://login.microsoftonline.com/<tenant-id>`. Only set when a tenant was given; omitted defaults gotrue to the `common` endpoint. |

`ENABLE_AZURE_AD`, `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` are also persisted
(non-secret) in `config/installer.env`, so `sentinel-ops azure status` and a
later `sentinel-ops azure enable` can show/reuse them. **The client secret is
never written there** — it lives only in `supabase/.env` (`chmod 600`),
matching every other Supabase secret. `prompt_secret()` reads it with the
terminal echo off and it is never passed to `run_logged` or anything else that
writes to the installer log.

## Redirect URI

Register this exact value on the app registration before enabling:

```
<API_EXTERNAL_URL>/auth/v1/callback
```

`sentinel-ops azure status` (and the install summary, when enabled at install
time) prints the current value.

## Enabling it

At install time, the installer asks. On an existing installation:

```bash
sudo sentinel-ops azure enable     # prompts for Client ID, secret, tenant
sudo sentinel-ops azure status
sudo sentinel-ops azure disable
```

`enable` writes the configuration, patches `docker-compose.yml` if needed, and
restarts only the `auth` service (`docker compose up -d --force-recreate auth`)
— nothing else in the stack is touched.

## Troubleshooting

**"This Supabase release's docker-compose.yml has no Azure AD wiring to
enable."** The `GOTRUE_EXTERNAL_AZURE_REDIRECT_URI` line `azure_patch_compose()`
looks for as an anchor is not present at all in this release's compose file —
upstream restructured it. `.env` is configured correctly; the compose file
needs the equivalent lines added by hand for this specific release.

**Sign-in redirects but fails immediately.** Almost always a redirect URI
mismatch — it must match `<API_EXTERNAL_URL>/auth/v1/callback` exactly,
including scheme and trailing slash (there is none). An installation enabled
before this path was corrected to include `/auth/v1` still has the old value
wired into `docker-compose.yml`; run `sentinel-ops repair apply` to re-wire it
and restart Auth, then update the redirect URI registered in Entra ID to
match. See [../README.md#repairing-supabaseenv](../README.md#repairing-supabaseenv).

**Works for some accounts and not others.** `AZURE_URL` (the tenant) is unset,
so gotrue is using the `common` endpoint. Set a tenant ID with
`sentinel-ops azure enable` to restrict sign-in to one directory.

**Nothing happens after `azure enable`.** Check `sentinel-ops logs supabase`
for the `auth` container restarting; `sentinel-ops status` reports whether Auth
is healthy.
