# Backups and 3-2-1

A default install takes local, full-stack backups automatically (before every
migration run, application update, Supabase update and restore). This page
covers the full layout, how to restore any scope from any copy, and how to
turn that into a real **3-2-1** setup: 3 copies of your backups, on 2
different media, with 1 of them offsite.

```bash
sentinel-ops backup create              # take one now
sentinel-ops backup list                # what's on disk
sentinel-ops backup verify              # checksum the latest (or a given one)
sentinel-ops restore                    # restore the latest local backup
```

## What's in a backup

Each backup is one directory under `backups/<timestamp>/`, and captures
enough to rebuild the whole install on a fresh box — not just the database:

```
/opt/sentinel-ops/backups/2026-09-11-121500/
├── database.sql       pg_dumpall --clean --if-exists (roles and all databases)
├── storage.tar.gz      Supabase Storage's uploaded objects
├── functions.tar.gz    the deployed edge functions
├── config.tar.gz        supabase/.env + installer.env + the deploy key (chmod 600)
├── checksums.txt        sha256 of every file above
└── metadata.txt         timestamp, reason, versions, sizes
```

`config.tar.gz` holds real secrets (`JWT_SECRET`, `POSTGRES_PASSWORD`, API
keys) — it's chmod 600 the moment it's written, and restoring it is a
separate, explicitly-confirmed step (see below) because it invalidates every
current session and issued token.

Local retention is count-based: `BACKUP_RETENTION_COUNT` (default 10, in
`config/installer.env`) — the oldest cycles are pruned once that limit is
passed.

## Restoring

```bash
sentinel-ops restore                                    # latest local backup, database only
sentinel-ops restore 2026-09-11-121500                   # a specific local backup
sentinel-ops restore --scope=full                        # + Storage, functions and (on confirmation) config
sentinel-ops restore --from=secondary --scope=full        # from the secondary repository
sentinel-ops restore --from=offsite --snapshot=<id>       # a specific offsite snapshot (default: latest)
```

Every restore, regardless of source:

1. Verifies the backup's checksums before touching anything live.
2. Shows its metadata and asks for confirmation.
3. Takes a fresh safety backup of the current state first.
4. Restores the database.
5. With `--scope=full`, also restores Storage and edge functions, then asks
   a **second, separate** confirmation before restoring `config.tar.gz` (it
   overwrites live secrets).
6. Restarts Supabase and health-checks it.

`--from=secondary`/`--from=offsite` pulls the chosen snapshot down from that
restic repository into a temporary staging directory first, then runs the
exact same restore steps above — a restic-sourced restore is not a different
code path, just a different source directory.

## Setting up 3-2-1

| Copy | What | Command |
|---|---|---|
| 1 | Local backups under `backups/` (this host, same disk) | on by default |
| 2 | **Secondary** — a different local/attached medium (second disk, NAS mount, ...) | `sentinel-ops remote secondary configure` |
| 3 | **Offsite** — a remote/cloud target | `sentinel-ops remote offsite configure` |

Both replication targets are [restic](https://restic.net) repositories:
restic handles encryption, deduplication and retention, so nothing here
implements its own crypto. A repository is just a URL — restic supports a
local path, `s3:...`, `b2:...`, `sftp:...` and more; see [restic's own
docs](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html)
for the full list and what credentials each backend needs.

```bash
sentinel-ops remote secondary configure   # e.g. a mounted second disk or NAS share
sentinel-ops remote offsite configure     # e.g. an S3-compatible bucket
sentinel-ops remote status                # both roles at a glance
```

`configure` prompts for:

- the repository URL
- a repository password (generated for you if left blank — this is what
  encrypts the repository; **write it down**, restic cannot recover a
  repository without it)
- any backend credentials the URL needs (e.g. `AWS_ACCESS_KEY_ID`/
  `AWS_SECRET_ACCESS_KEY` for an S3 URL) — entered as `KEY=VALUE` pairs,
  blank to finish
- retention: how many daily/weekly/monthly snapshots to keep (`restic forget
  --prune` applies this on every scheduled cycle)

Credentials never appear in `config/installer.env`. They live in:

```
config/restic-<role>.pass   the repository password       chmod 600
config/restic-<role>.env    backend credentials (KEY=VALUE) chmod 600
```

`sentinel-ops remote secondary check` / `offsite check` runs `restic check`
against that repository on demand; `... forget` re-applies the retention
policy on demand. Both run automatically as part of the scheduled cycle
below.

## Scheduling

```bash
sentinel-ops schedule enable     # prompts for a systemd OnCalendar expression (default: daily)
sentinel-ops schedule status
sentinel-ops schedule disable
sentinel-ops schedule run-now    # run a full cycle immediately, without waiting for the timer
```

`schedule enable` installs a `sentinel-ops-backup.timer`/`.service` pair
(`systemctl status sentinel-ops-backup.timer`, logs via `journalctl -u
sentinel-ops-backup.service`). Each scheduled cycle:

1. Takes a full local backup (**fatal** if this fails — nothing else runs).
2. Replicates it to `secondary`/`offsite`, for each that's configured
   (**a replication failure is a loud warning, not fatal** — the local
   backup must survive even if the network or cloud target is down).
3. Applies the configured retention policy to each configured repository.
4. Verifies the local backup's checksums.
5. On the configured check day (`BACKUP_SCHEDULE_CHECK_DAY`, default `Sun`),
   runs `restic check` against each configured repository. This is
   deliberately not every night — a full repository check reads more data
   and takes longer than a plain backup, so it runs weekly by default.

If this host has no `systemd` (containers, WSL), `schedule enable` warns and
does nothing further — run `sentinel-ops schedule run-now` by hand instead
(from your own cron, if you want it scheduled anyway).

`sentinel-ops status` and `sentinel-ops remote status` both show the last
replication and check time for each configured role, so a silent offsite
failure doesn't go unnoticed.

## Verification: what this does and doesn't check

Every backup is checksummed (`checksums.txt`), and `sentinel-ops backup
verify` / the scheduled cycle both recompute and compare those hashes before
trusting a backup. Configured repositories get a periodic `restic check`,
which verifies the repository's internal structure and that its data is
readable.

This is **not** an automated restore drill — nothing spins up a scratch
database to prove a backup actually restores end-to-end. Periodically test a
real restore yourself, ideally on a disposable install (`sentinel-ops nuke &&
sentinel-ops install`, then restore into it), especially after changing
Postgres versions or the backup layout.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `remote ... configure` fails to install restic | No network access, or an unsupported architecture for the static-binary fallback — install `restic` yourself and re-run `configure`. |
| `restic_init`/`configure` fails | The repository URL or backend credentials are wrong. Re-run `configure` to update them. |
| Scheduled cycle logs a replication warning | `sentinel-ops remote <role> status` — check the last-backup time, then `sentinel-ops remote <role> check` for a repository-level check. |
| `schedule enable` warns "systemctl not available" | No systemd on this host. Run `sentinel-ops schedule run-now` from your own cron instead. |
| Rotating a leaked/expired backend credential | `sentinel-ops remote <role> configure` again — it overwrites `config/restic-<role>.env`. |
| Backup verification fails | The backup is corrupt — do not restore it. Fall back to an older local backup, or a secondary/offsite snapshot: `sentinel-ops restore --from=secondary`. |
