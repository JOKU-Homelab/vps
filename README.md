# VPS infrastructure

Infrastructure as code for an AlmaLinux/RHEL VPS. Host automation, Compose files, service configuration templates, and recovery tooling live in this repository. Runtime configuration and service secrets live in Infisical.

## Install

To apply host hardening only, without Docker or application stacks:

```bash
curl -fsSL https://raw.githubusercontent.com/JOKU-Homelab/vps/main/install-hardening.sh | sudo bash
```

This creates or updates `/etc/vps-bootstrap/init.json` as you enter the admin username and SSH public key. It enables host security components (firewalld and CrowdSec) and automatic security updates, but does not install Docker or deploy application stacks.

Create an Infisical project and a Universal Auth machine identity with read/write access to the project path used by the installer. Store the project configuration values in that project. The installer defaults to Infisical Cloud, and accepts a custom HTTPS endpoint for a self-hosted Infisical instance.

Run on a fresh VPS:

```bash
curl -fsSL https://raw.githubusercontent.com/JOKU-Homelab/vps/main/install.sh | sudo bash
```

The installer prompts for Infisical endpoint, project/environment/path, and machine identity access. It creates generated secrets and configuration placeholders in Infisical, pauses while you complete the values, then initializes the host. It starts Pangolin first, pauses for Pangolin's first administrator and site setup, then enables ComposeFlux.

The installer identity is kept root-only at `/etc/vps-bootstrap/infisical.env`; it is used for bootstrap and backup operations. ComposeFlux receives a separate read-only identity from `/etc/vps-bootstrap/composeflux.env`. Both files contain only Infisical access details and are root-only. The installer identity needs write access only while a new project is seeded; reduce it to read-only access afterward. All service configuration and credentials, including SMTP and backup access, live in Infisical. Protect an off-host copy of the bootstrap identity for recovery, or be prepared to enter it again on a replacement server.

## Restore

On a replacement VPS, run the installer and enter access to the same Infisical project. Wait for the installer's secret checks, then select the backup:

```bash
curl -fsSL https://raw.githubusercontent.com/JOKU-Homelab/vps/main/install.sh | sudo bash -s -- --restore latest
```

The backup repository, object-store credentials, and Restic password come from Infisical. The installer restores service data under `/opt`; the new host's Infisical access credential and SSH configuration stay in place. See [backup and disaster recovery](stacks/backrest/README.md).

## Repository map

```text
ansible/          Host initialization, hardening, backup role, and playbooks
composeflux/      ComposeFlux bootstrap and secret-provider documentation
stacks/           Pangolin, ComposeFlux, and application Compose projects
install.sh        Fresh-host bootstrap and full restore entry point
```

Persistent application data is bind-mounted under `/opt`, not Docker named volumes. Renovate tracks image and action updates; minor and patch updates are configured for automerge. See [Renovate setup](stacks/renovate/README.md).

Before making the repository public, review its Git history and rotate any credentials that may have appeared in earlier commits.
