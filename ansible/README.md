# Ansible operations

The installer runs Ansible locally on the VPS. Ansible hardens the host, installs Docker and backup tooling, restores data when requested, renders Pangolin configuration, and starts Pangolin. Infisical is the source for host configuration and service secrets.

## Infisical prerequisites

Before running the installer, create a project and a Universal Auth machine identity with read/write access to the selected environment and path. The installer asks for:

- Infisical HTTPS endpoint (`https://eu.infisical.com` by default; a self-hosted URL is accepted)
- Project ID, environment, and secret path
- Universal Auth client ID and secret

The bootstrap client secret is kept in `/etc/vps-bootstrap/infisical.env` with root ownership and mode `0600`. It needs write access only when the project is first seeded; afterward reduce its role to read-only so scheduled backups and future restores can retrieve secrets without write access. After Pangolin setup, create a separate read-only machine identity for ComposeFlux; the installer stores it in `/etc/vps-bootstrap/composeflux.env`, also mode `0600`.

## Install flow

```bash
curl -fsSL https://raw.githubusercontent.com/JOKU-Homelab/vps/main/install.sh | sudo bash
```

The installer seeds generated secrets and `CHANGE_ME` configuration values, then waits while you complete them in Infisical. It validates required values before running Ansible. Pangolin starts first. Complete its first-admin wizard, create a site, enter `PANGOLIN_ENDPOINT`, `SITE_ID`, and `SITE_SECRET` in Infisical, and continue the installer to enable ComposeFlux.

The required secret keys are listed in the installer's prompt and in the Compose files under `stacks/`. SMTP values and Restic/B2 credentials are also read directly from Infisical. Migadu implicit TLS should use `SMTP_PORT=465` and `SMTP_SECURE=true`.

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
