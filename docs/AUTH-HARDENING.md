# Auth hardening

Supabase Auth (`gotrue`) ships with permissive defaults: anyone can sign up,
a 6-character password is enough, and on a self-hosted stack there is no
per-IP rate limit at all. The installer can tighten five of these settings.
**All five are off by default.** An install that answers "no" to every prompt
behaves exactly as it did before this feature existed.

| Feature | `sentinel-ops auth enable …` | What gotrue gets |
|---|---|---|
| Admin-created accounts only | `signup` | `GOTRUE_DISABLE_SIGNUP=true` |
| Strong password policy | `password-policy` | `GOTRUE_PASSWORD_MIN_LENGTH`, `GOTRUE_PASSWORD_REQUIRED_CHARACTERS` |
| Reject breached passwords | `hibp` | `GOTRUE_PASSWORD_HIBP_ENABLED`, `GOTRUE_PASSWORD_HIBP_FAIL_CLOSED` |
| CAPTCHA on sign-in (Turnstile) | `captcha` | `GOTRUE_SECURITY_CAPTCHA_ENABLED/PROVIDER/SECRET` |
| Per-IP rate limiting | `rate-limit` | `GOTRUE_RATE_LIMIT_HEADER` (+ optional `GOTRUE_RATE_LIMIT_TOKEN_REFRESH`) |

You can turn each one on at install time (one prompt per feature) or later:

```bash
sudo sentinel-ops auth status
sudo sentinel-ops auth enable password-policy
sudo sentinel-ops auth disable captcha
```

`enable` and `disable` save the setting and recreate the `auth` container.
For `captcha` they also restart the frontend.

## How the settings reach gotrue

Upstream's `docker-compose.yml` already passes `GOTRUE_DISABLE_SIGNUP` through
from `${DISABLE_SIGNUP}`, so **signup** is a plain `supabase/.env` setting.

None of the other variables appear in upstream's compose file. Putting them in
`.env` alone does nothing. The installer generates an overlay instead,
`supabase/docker-compose.sentinel-auth.yml`, which adds only those keys to the
`auth` service. It is registered in `COMPOSE_FILE` in `supabase/.env`,
alongside upstream's own optional overlays such as `docker-compose.logs.yml`.
The overlay is rewritten on every install, `update supabase`, `repair apply`
and `auth` run. **Don't edit it.** Change the settings in
`config/installer.env` or with `sentinel-ops auth` instead. When every
overlay-backed feature is off, the file is deleted and removed from
`COMPOSE_FILE`. See [DECISIONS.md](DECISIONS.md) #28.

Settings, in `config/installer.env`:

```
AUTH_DISABLE_SIGNUP=false
AUTH_PASSWORD_POLICY=false
AUTH_PASSWORD_MIN_LENGTH=12
AUTH_HIBP_ENABLED=false
AUTH_HIBP_FAIL_CLOSED=false
AUTH_CAPTCHA_ENABLED=false
TURNSTILE_SITE_KEY=
AUTH_RATE_LIMIT_HEADER=
AUTH_RATE_LIMIT_TOKEN=
```

If you edit this file by hand, run `sudo sentinel-ops repair apply` afterwards
to re-apply and restart.

## Features

### signup — admin-created accounts only

Turns off `POST /auth/v1/signup` for the public API key. Admins can still
create accounts through the service-role admin API (`auth.admin.createUser`):
the user-management screens, bulk import, first-admin setup and agent
registration are unaffected.

**Azure AD:** with sign-up disabled, gotrue may refuse an SSO user signing in
for the first time if they have no account yet. Provision those users first
(for example with the employee sync), and test one SSO login after enabling
this.

`hardening_apply_config` only ever turns sign-up *off*. Turning it back on is
always an explicit `sentinel-ops auth disable signup`, so a `DISABLE_SIGNUP=true`
you set by hand is never reverted.

**Verify:** `curl -X POST -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' -d '{"email":"x@example.com","password":"Xx1!xxxxxxxx"}' $SUPABASE_PUBLIC_URL/auth/v1/signup`
should return `422` with `signup_disabled`.

### password-policy — length and character classes

The minimum length is 12 by default (asked at enable time, never below 6).
Every password must contain lowercase and uppercase letters, digits and
symbols. These are the same sets as hosted Supabase's
"lower_upper_letters_digits_symbols" option.

gotrue enforces this on every path that **sets** a password, including the
admin API, so every client is covered. Existing passwords keep working until
they are next changed.

**Verify:** creating a user with `Password1` or `admin123` fails with
`weak_password`.

### hibp — reject breached passwords

Checks each new password against the
[Pwned Passwords](https://haveibeenpwned.com/Passwords) range API, using
k-anonymity: only the first 5 characters of the SHA-1 hash leave the host.
This needs outbound HTTPS from the auth container to
`api.pwnedpasswords.com`.

No API key or account is needed; the range API is free.

**Health check before enabling.** `auth enable hibp`, and the install-time
prompt, first make a real request to the API. They look up the hash range for
`password` and require its known hash in the answer, so a bare HTTP 200 from a
captive portal or an intercepting proxy doesn't count. The request runs from
the `auth` container when Supabase is running, because that container makes
the real requests. Before Supabase is up, it runs from the host. If the check
fails, the feature is **not enabled** and the installer says which egress to
open. `sentinel-ops status` and `auth status` repeat the check, and show a
warning if an enabled check can no longer reach the API.

By default it **fails open**: if that API can't be reached, the password is
accepted. On an air-gapped host, choose fail-closed only if you accept that
nobody can set a password while the API is unreachable.

### captcha — Cloudflare Turnstile on sign-in

1. Create a Turnstile widget in the Cloudflare dashboard for the application's
   hostname.
2. Run `sentinel-ops auth enable captcha` and enter the site key and secret key.

The **secret** is written only to `supabase/.env` (`TURNSTILE_SECRET_KEY`,
chmod 600). The overlay refers to it by name, so it never appears in the
overlay, in `installer.env` or in the log. The **site key** is public: it is
saved in `installer.env` and passed to the frontend container as
`TURNSTILE_SITE_KEY`, which the application serves to the browser.

**The application must send the CAPTCHA token**, or every password sign-in is
rejected once this is on. The installer checks whether the application
checkout reads `TURNSTILE_SITE_KEY`, and asks for explicit confirmation if
it doesn't.

Both sides need to reach `challenges.cloudflare.com`. The browser loads the
widget from it. The **`auth` container** checks every sign-in token there,
sending the token and the secret to Cloudflare's `siteverify` endpoint, so a
server without outbound HTTPS can't use this feature.

**Health check before enabling.** The installer sends the secret and a dummy
token to `siteverify`. It does this from the `auth` container when Supabase is
running, and from the host before then. Cloudflare's answer tells the cases
apart:

| Answer | Meaning | Result |
|---|---|---|
| `invalid-input-response` | The secret is valid; only the dummy token was rejected | enabled |
| `invalid-input-secret` | Wrong or truncated secret | **not** enabled |
| `result_with_testing_key` | One of Cloudflare's public test secrets (no protection) | **not** enabled |
| no answer, or a non-Cloudflare page | No route to Cloudflare | **not** enabled |

The secret never appears on a command line: `curl` reads it from stdin, and
`docker exec` takes it from the environment. `sentinel-ops status` and
`auth status` repeat the check. If an enabled CAPTCHA starts failing (for
example, the key was rotated in Cloudflare or egress was closed), they warn
that password sign-in is being refused.

gotrue applies the CAPTCHA to every password grant, not only browser ones, so
check any server-side caller that signs in with a password before you enable
it.

### rate-limit — per-IP limiting keyed on the real client

Self-hosted gotrue applies **no** per-IP rate limit unless
`GOTRUE_RATE_LIMIT_HEADER` names a header that carries the client address. A
request without that header is let through, and gotrue logs a warning. Once
the header is set, gotrue's built-in limits apply per client IP:

- sign-in and token refresh share one limiter: 150 requests per 5 minutes by
  default, with a burst of 30. Override with `AUTH_RATE_LIMIT_TOKEN`.
- sign-up, OTP, verify and the other endpoints have their own limiters.

Pick the header carefully:

- **Don't use `X-Forwarded-For`.** The Envoy gateway in current Supabase
  releases appends to it, so its first entry (the one gotrue reads) is
  whatever the client sent.
- **Don't use `X-Real-IP`.** Kong (older releases) overwrites it with the
  address of whatever connected to Kong. Behind a proxy that is the proxy
  itself, so every user would share one bucket.
- **Use a dedicated header** that only your edge proxy sets. The default is
  `X-Sentinel-Client-IP`. Neither gateway touches it.

Requirements:

1. The reverse proxy must **overwrite** the header on every request (nginx
   `proxy_set_header X-Sentinel-Client-IP $remote_addr;`). See
   [REVERSE-PROXY.md](REVERSE-PROXY.md#sign-in-rate-limiting-optional), which
   also shows an extra `limit_req` on `/auth/v1/token` at the proxy.
2. The Supabase API port (8000) must not be reachable except through that
   proxy. Otherwise a client can talk to the gateway directly and set the
   header itself.

**Verify:** through the proxy, 30+ rapid failed sign-ins from one address
return `429`.

## Not covered here

Some auth protections live in the application rather than in gotrue's
environment, and come with application releases:

- per-account lockout after repeated failures
- client-side password-strength hints
- the CAPTCHA widget itself
