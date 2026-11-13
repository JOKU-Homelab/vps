# Backrest, Restic, and disaster recovery

Backrest provides a UI for snapshot browsing. The repository's host-side `vps-backup` command is the default scheduler and recovery path: Ansible installs it with a daily systemd timer after backup credentials are provisioned. Do not schedule duplicate backup plans in the Backrest UI unless you want duplicate snapshots. Persistent service data is bind-mounted beneath `/opt`; Docker volumes are not part of the recovery layout.

The Backrest container has read-only access to `/opt` and the PostgreSQL dump staging directory. It has no Docker socket and no published host port; Pangolin routes its UI. Its image and the Restic CLI image are versioned in this stack so Renovate can update both.

## Configure off-host storage

Create a private object-storage bucket and a key limited to that bucket. Configure a Restic repository and a strong repository password. Store these values in Infisical as the operational source of truth, and keep an off-host recovery copy in an operator password manager. The host timer needs a root-only local copy so it can run without an interactive Infisical login; this is part of the bootstrap recovery material. Restic encrypts repository contents, but losing the password makes snapshots unreadable. Do not apply provider lifecycle deletion rules; retention is managed with Restic.

Install these files on the VPS, each owned by root with mode `0600`:

- `/etc/vps/backup.env`: `RESTIC_REPOSITORY`, `B2_ACCOUNT_ID`, and `B2_ACCOUNT_KEY`.
- `/etc/vps/restic-password`: the Restic repository password.

Example `backup.env` shape (fill in values locally; never commit it):

```sh
RESTIC_REPOSITORY=b2:bucket-name:repository-prefix
B2_ACCOUNT_ID=replace-with-bucket-key-id
B2_ACCOUNT_KEY=replace-with-bucket-key
```

Copy the values from Infisical into those two host files, then run `vps-backup init` once for a new repository. The installer initializes it on first setup. Ansible enables the daily timer only after both credential files exist. The scheduled job exports every running PostgreSQL container to temporary SQL dumps, aborts if any export fails, snapshots `/opt` and host configuration, then applies retention of 7 daily, 4 weekly, and 12 monthly snapshots. Temporary plaintext dumps are removed after the backup attempt.

## Snapshot contents and limits

The backup includes `/opt`, `/etc/vps`, `/etc/vps-bootstrap`, and PostgreSQL logical exports. Persistent service data is bind-mounted under `/opt`, so replacement servers do not depend on Docker volume names. It excludes the Restic repository credentials, password, and `/etc/vps/install.conf` because that bundle contains the credentials needed to decrypt the repository. Git checkouts are excluded because the repository can be fetched again. Infisical bootstrap environment files are included inside the encrypted snapshot; keep an independent protected copy of `install.conf` off-host.

PostgreSQL dumps are an application-aware recovery source. A filesystem copy of a live database can still be crash-consistent and depends on the matching PostgreSQL major version. If a database directory fails to start, use its SQL dump from protected restore staging to initialize a clean matching database. SQLite and other changing files may only be crash-consistent; use a service-specific export or short maintenance window when consistency matters.

Run repository checks regularly:

```sh
vps-backup snapshots
vps-backup check
vps-backup check --read-data
```

Full data checks can take time and bandwidth. Do a real restore drill periodically.

## Full restore on a new VPS

The installer can initialize a replacement VPS and restore a selected snapshot before starting services. Back up the generated `/etc/vps/install.conf` off-host; it includes the settings and credentials needed to run the restore without prompts:

```bash
curl -fsSL https://raw.githubusercontent.com/JOKU-Homelab/vps/main/install.sh | sudo bash -s -- --config /root/install.conf
```

Copy `install.conf` to the new host, point the provider firewall at it, and run the command above. The installer fetches the configured ref, restores the latest snapshot to protected staging, stops Docker, restores `/opt` and the previous Infisical/Pangolin/ComposeFlux bootstrap files, then starts Docker and deploys the core services. It keeps the new host's SSH/user configuration and homes. Use `--restore SNAPSHOT` to select a specific snapshot. No prompts are required.

After the first boot:

1. Check Pangolin, Infisical, and ComposeFlux container health and logs.
2. If a PostgreSQL data directory fails, use the matching dump under `/opt/vps/backup/staging/restore-*/staging/postgresql/` to restore into a clean database. Keep the database major version the same as the dump source. For a new empty PostgreSQL instance, copy the dump to it and run `docker exec -i CONTAINER psql -U POSTGRES_USER -d postgres < dump.sql` from a root shell.
3. Verify Infisical can decrypt and return secrets, Pangolin login and resources work, services pass their health checks, TLS certificates are valid, and the daily backup timer is enabled.
4. Record the snapshot ID, recovery start/end time, and any manual database recovery steps. Remove the protected restore staging directory after verification because it contains plaintext data.
5. Once service health and the new DNS/provider firewall are confirmed, run `vps-backup backup`, then `vps-backup snapshots` and `vps-backup check`. Confirm a snapshot exists before attempting a clean-server recovery drill.

The normal service install uses the same repository Compose files and Infisical credentials as the restored deployment. The installer starts ComposeFlux automatically when the snapshot contains its configured machine identity. The Infisical database and encryption key must be restored together. Keep Restic credentials and Infisical bootstrap recovery material outside the VPS as well as inside encrypted snapshots.

## Recovery notes

- **Target recovery time and data loss:** Set an operational RTO/RPO for the services you care about. The daily snapshot schedule has a worst-case backup-point age of about one day, plus the time since the last successful run; it does not guarantee a recovery time.
- **Infisical unavailable:** Restore its PostgreSQL data directory under `/opt/vps/data/infisical/` and the exact encryption key and auth secret from the same snapshot. ComposeFlux's machine identity is restored in its root-only bootstrap file.
- **Pangolin unavailable:** Restore its config tree, database, certificates, generated Gerbil key, and the Pangolin server secret together. Keep the same public base domain.
- **Single application needs recovery:** Use `vps-backup restore SNAPSHOT EMPTY_DIRECTORY` and copy only the required files, or restore its PostgreSQL database from the matching logical dump. Avoid replacing the entire `/opt` tree for a single-service incident.
- **After any restore:** Rotate credentials that may have been accessible during the incident, verify access controls and public routes, then create and check a new snapshot.

## Manual file restore

For a targeted restore, choose an empty absolute directory:

```sh
mkdir -p /mnt/recovery
vps-backup restore latest /mnt/recovery
```

Inspect the restored tree before copying selected files into live service paths. The command derives the Restic image tag from this stack's Compose file, so Renovate keeps it current.
