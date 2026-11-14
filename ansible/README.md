# Ansible operations

The installer runs Ansible locally on the VPS. Ansible hardens the host, installs Docker and backup tooling, restores data when requested, renders Pangolin configuration, and starts Pangolin. Infisical is the source for host configuration and service secrets.

## Infisical prerequisites

Before running the installer, create a project and a Universal Auth machine identity with read/write access to the selected environment and path. The installer asks for:

- Infisical HTTPS endpoint (`https://eu.infisical.com` by default; a self-hosted URL is accepted)
- Project ID and environment (the installer creates and uses service-specific secret folders)
- Universal Auth client ID and secret

The bootstrap client secret is kept in `/etc/vps-bootstrap/infisical.env` with root ownership and mode `0600`. It needs write access only when the project is first seeded; afterward reduce its role to read-only so scheduled backups and future restores can retrieve secrets without write access. After Pangolin setup, create a separate read-only machine identity for ComposeFlux; the installer stores it in `/etc/vps-bootstrap/composeflux.env`, also mode `0600`.

## Install flow

```bash
curl -fsSL https://raw.githubusercontent.com/JOKU-Homelab/vps/main/install.sh | sudo bash
```

The installer creates folders for bootstrap, SMTP, backups, Pangolin, Authentik, Backrest, Beszel, Databasement, Renovate, and ComposeFlux. It seeds generated secrets and `CHANGE_ME` configuration values with a per-secret comment describing each value, then waits while you complete them in Infisical. It validates required values before running Ansible. Pangolin starts first. Complete its first-admin wizard, create a site, enter `PANGOLIN_ENDPOINT`, `SITE_ID`, and `SITE_SECRET` in `/pangolin-site`, and continue the installer to enable ComposeFlux.

The required secret keys are listed in the installer's prompt and in the Compose files under `stacks/`. SMTP values live in `/smtp`; Restic/B2 credentials live in `/backup`. ComposeFlux reads the configured service folders as a comma-separated path list. Migadu implicit TLS should use `SMTP_PORT=465` and `SMTP_SECURE=true`.

## Existing host operations

The production and bootstrap inventories contain documentation-only example values. Copy them to ignored `*local*.yml` files and set the host, account, and SSH key before remote Ansible use. Never put real host details or keys in tracked inventory.

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory/production.local.yml playbooks/configure-vps.yml
```

Keep an existing session and provider console available while changing SSH or firewall settings. Docker-published ports do not all follow the host firewall's ordinary input rules.

## Restore

On a replacement VPS, provide the same Infisical project values and run:

```bash
curl -fsSL https://raw.githubusercontent.com/JOKU-Homelab/vps/main/install.sh | sudo bash -s -- --restore latest
```

Ansible restores service data before starting Pangolin. The new host's Infisical access file remains in place, while the snapshot restores `/opt`. See the [backup and disaster recovery guide](../stacks/backrest/README.md).

## Hardening

See [HARDENING.md](HARDENING.md) for SSH, SELinux, firewalld, Docker, automatic updates, and CrowdSec behavior.
