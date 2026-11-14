# Backrest, Restic, and disaster recovery

Backrest provides a UI for snapshot browsing. The host-side `vps-backup` command is the scheduled backup and recovery path. Ansible installs a daily systemd timer, which obtains backup credentials from Infisical each time it runs. Avoid duplicate schedules in the Backrest UI unless you intentionally want additional snapshots.

Persistent service data is bind-mounted beneath `/opt`; Docker named volumes are not part of the recovery layout. The Backrest container has read-only access to `/opt` and the PostgreSQL dump staging directory. It has no Docker socket and no published host port; Pangolin routes its UI.

## Infisical backup values

Store these keys in the configured Infisical project/environment/path:

- `RESTIC_REPOSITORY` (for example `b2:bucket-name:repository-prefix`)
- `B2_ACCOUNT_ID`
- `B2_ACCOUNT_KEY`
- `RESTIC_PASSWORD`

The installer seeds `RESTIC_PASSWORD` once and creates the repository on first setup. Set the other values in Infisical before continuing. Keep an independent recovery copy of the Infisical Universal Auth credential and the Restic password in a password manager. Restic encrypts repository contents; losing its password makes snapshots unreadable. Do not set provider lifecycle deletion rules; Restic manages retention.

The systemd job authenticates to Infisical for each run and injects credentials into the Restic container process. It exports every running PostgreSQL container to temporary SQL dumps, aborts if any export fails, snapshots `/opt` and relevant host configuration, and applies retention of 7 daily, 4 weekly, and 12 monthly snapshots. Temporary plaintext dumps are removed after the backup attempt.

Run maintenance commands through the Infisical wrapper so it can fetch the repository credentials:

```sh
/usr/local/sbin/vps-infisical-run /usr/local/sbin/vps-backup snapshots
/usr/local/sbin/vps-infisical-run /usr/local/sbin/vps-backup check
/usr/local/sbin/vps-infisical-run /usr/local/sbin/vps-backup check --read-data
```

Full data checks can take time and bandwidth. Do a real restore drill periodically.

## Snapshot contents and limits

Snapshots include `/opt`, `/etc/vps`, and PostgreSQL logical exports. They exclude the local Infisical connection credential, because a replacement host must use its own current credential. Git checkouts are excluded because the repository can be fetched again. Persistent service data is bind-mounted under `/opt`, so replacement servers do not depend on Docker volume names.

PostgreSQL dumps are an application-aware recovery source. A filesystem copy of a live database may be only crash-consistent and depends on the matching PostgreSQL major version. If a database directory fails to start, use its SQL dump from protected restore staging to initialize a clean matching database. SQLite and other changing files may also be crash-consistent; use a service-specific export or maintenance window when consistency matters.

## Full restore on a new VPS

Create a new Universal Auth identity with access to the same Infisical project, or use the existing recovery identity. On a fresh AlmaLinux VPS, run:

```bash
curl -fsSL https://raw.githubusercontent.com/JOKU-Homelab/vps/main/install.sh | sudo bash -s -- --restore latest
```

The installer prompts for the Infisical endpoint, project location, and machine identity if the local connection file does not exist. It retrieves the Restic credentials from Infisical, restores `/opt` before starting services, then deploys the repository's current configuration. Use `--restore SNAPSHOT` to select a specific snapshot. The local Infisical connection file and new host access configuration remain in place.

For recovery to complete, the Infisical instance and project must be reachable and must contain the current service secrets. If Infisical itself is unavailable, restore it separately or recover Infisical access first; it is an external prerequisite for this deployment design.

After the first boot:

1. Check Pangolin and ComposeFlux container health and logs.
2. If a PostgreSQL data directory fails, use the matching dump under `/opt/vps/backup/staging/restore-*/staging/postgresql/` to initialize a clean database of the same major version. For an empty PostgreSQL instance, copy the dump to it and run `docker exec -i CONTAINER psql -U POSTGRES_USER -d postgres < dump.sql` from a root shell.
3. Verify Infisical returns secrets, Pangolin login and resources work, services pass health checks, TLS certificates are valid, and the daily backup timer is enabled.
4. Record the snapshot ID, recovery start/end time, and manual database steps. Remove the protected restore staging directory after verification because it contains plaintext data.
5. Run a new backup and verify it with `vps-backup snapshots` and `vps-backup check` through `vps-infisical-run`.

## Recovery notes

- **Target recovery time and data loss:** Set an operational RTO/RPO. Daily snapshots have a worst-case backup-point age around one day plus time since the last successful run; they do not guarantee recovery time.
- **Infisical unavailable:** Restore access to the Infisical project before using this installer. Keep an off-host copy of the Universal Auth recovery credential and the Restic password. Without Infisical access or those credentials, automated restore cannot retrieve the repository secrets.
- **Pangolin unavailable:** Restore its config tree, database, certificates, generated Gerbil key, and `SERVER_SECRET` together. Keep the same public base domain.
- **Single application recovery:** Use `vps-infisical-run /usr/local/sbin/vps-backup restore SNAPSHOT EMPTY_DIRECTORY` and copy only the needed files, or restore its PostgreSQL database from a matching logical dump. Avoid replacing the entire `/opt` tree for a single-service incident.
- **After any restore:** Rotate credentials that may have been accessible during the incident, verify access controls and public routes, then create and check a new snapshot.

## Manual file restore

Choose an empty absolute directory:

```sh
mkdir -p /mnt/recovery
/usr/local/sbin/vps-infisical-run /usr/local/sbin/vps-backup restore latest /mnt/recovery
```

Inspect the restored tree before copying selected files into live service paths. The command derives the Restic image tag from this stack's Compose file, so Renovate keeps it current.
