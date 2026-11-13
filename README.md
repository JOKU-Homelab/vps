# VPS infrastructure

Infrastructure as code for a single AlmaLinux VPS. The repository is the source of truth for host automation, service Compose files, and non-secret configuration.

## Deployment model

1. Run [`install.sh`](install.sh) on a fresh VPS. It downloads a selected repository ref, prompts for the host's SSH key and public service domain, and runs Ansible locally.
2. Ansible hardens the host, installs Docker, then starts Pangolin and self-hosted Infisical from their repository Compose files.
3. Complete Pangolin's first-admin setup and create a site. Complete Infisical's initial setup, add the site credentials and application secrets to an Infisical project, then create a least-privilege machine identity and configure ComposeFlux's root-only client settings.
4. Run `ansible-playbook ansible/playbooks/enable-gitops.yml`. ComposeFlux then deploys the `stacks/` projects, including the Pangolin site connector, and reconciles future changes from Git.

Example install command after the repository is public:

```bash
curl -fsSL https://raw.githubusercontent.com/JOKU-Homelab/vps/main/install.sh | sudo bash -s -- --ref v1.0.0
```

Use a release tag instead of `main` for repeatable installs. `install.sh --help` lists the supported options. The current bootstrap flow targets AlmaLinux/RHEL-family hosts.

## Secrets and recovery

Application secrets live in a dedicated Infisical project. The small bootstrap set needed to start Infisical and authenticate ComposeFlux lives root-only under `/etc/vps-bootstrap/` and must have off-host recovery copies. Never commit real `.env` files, secret exports, backups, private keys, or host-specific configuration.

Restic snapshots use an off-host object-storage repository. The repository includes a host-aware `vps-backup` command and a full-host restore path. Persistent service data is stored in bind-mounted directories under `/opt`, not Docker named volumes.

```bash
curl -fsSL https://raw.githubusercontent.com/JOKU-Homelab/vps/main/install.sh | sudo bash -s -- --config /root/install.conf
```

The installer creates `/etc/vps/install.conf`, a root-only recovery bundle containing host settings, bootstrap credentials, and backup credentials. Keep a protected copy off-server. On a fresh AlmaLinux VPS, `install.sh --config install.conf` fetches the repository, installs the host, and restores the latest snapshot without prompts. See [backup and disaster recovery](stacks/backrest/README.md).

## Repository map

```text
ansible/          Host initialization, hardening, backup role, and playbooks
composeflux/      ComposeFlux bootstrap notes and example local settings
stacks/           Pangolin, Infisical, ComposeFlux, and application Compose projects
install.sh        Fresh-host bootstrap and optional full restore entry point
```

All service images and Compose definitions are tracked under `stacks/`, including Pangolin, its Docker-socket-enabled site connector, Infisical, and ComposeFlux. Renovate proposes version updates; minor and patch updates are configured for automerge, while major updates remain manual. Follow the [Renovate setup guide](stacks/renovate/README.md) to enable GitHub-side automerge.

## Public release note

The current working tree is being scrubbed of host-specific details. That does not remove old values from Git history. Before changing repository visibility, review or rewrite the existing history and rotate any credentials that may have been exposed in earlier commits.
