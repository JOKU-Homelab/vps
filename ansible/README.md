# Ansible operations

Ansible owns host configuration and the first deployment of the core services. ComposeFlux owns ongoing application deployment after Infisical is initialized.

## Fresh VPS

Run the installer as root on a fresh AlmaLinux VPS, using a release tag:

```bash
curl -fsSL https://raw.githubusercontent.com/JOKU-Homelab/vps/main/install.sh | sudo bash -s -- --ref v1.0.0
```

The installer asks only for values missing from `/etc/vps/install.conf`; it saves each value as soon as it is accepted, so an interrupted setup can resume and later runs reuse the saved settings. An explicit partial `--config FILE` is also completed this way. A saved recovery bundle can restore the latest backup without prompts.

The installer writes the protected recovery bundle and bootstrap values under `/etc/vps-bootstrap/`, installs Ansible collections, and runs [`initialize-vps.yml`](playbooks/initialize-vps.yml) locally. Ansible configures users, SSH, SELinux when active, firewalld, security updates, Docker, CrowdSec, backup tooling, and persistent service directories under `/opt`, then starts Pangolin and Infisical from tracked Compose files.

Complete Pangolin's first-admin setup at `https://pangolin.YOUR_BASE_DOMAIN` and create a site for this host. Infisical's first account and machine identity require a one-time setup in its UI. Its setup port is bound to loopback; use an SSH tunnel from your workstation:

```bash
ssh -L 8080:127.0.0.1:18080 ADMIN_USER@YOUR_VPS_IP
```

The installer chooses a free host-side port in the `18080`–`18100` range and prints it at completion. If it chose a different port, use that number in the SSH command; it is saved as `INFISICAL_BOOTSTRAP_PORT` in `/etc/vps-bootstrap/infisical.env`. Open `http://127.0.0.1:8080`, create a dedicated project and production environment, add the secrets documented by each stack (including the Pangolin site endpoint, ID, and secret), then create a Viewer machine identity. Put its client ID and secret, the project ID, and other ComposeFlux settings in `/etc/vps-bootstrap/composeflux.env` (mode `0600`). Run:

```bash
ansible-playbook -i 'localhost,' -c local playbooks/enable-gitops.yml
```

ComposeFlux fetches the repository over HTTPS, reads the Infisical project, and deploys discovered stacks. It has Docker socket access, which is root-equivalent; only merge trusted changes.

## Existing host operations

The production and bootstrap inventories contain documentation-only example values. Copy them to ignored `*local*.yml` files and set the host, account, and SSH key before remote Ansible use. Never put real host details or keys in tracked inventory.

Run the hardening playbook from this directory after verifying that a fresh administrative SSH login works:

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory/production.local.yml playbooks/configure-vps.yml
```

Keep an existing session and provider console available while changing SSH or firewall settings. Docker-published ports do not all follow the host firewall's ordinary input rules.

## Restore on a replacement VPS

Copy the protected `install.conf` bundle to the new VPS, then run the installer without prompts:

```bash
curl -fsSL https://raw.githubusercontent.com/JOKU-Homelab/vps/main/install.sh | sudo bash -s -- --config /root/install.conf
```

The installer initializes the host, restores protected service data and bootstrap credentials before starting services, and starts ComposeFlux when the restored machine identity is present. Use `--restore SNAPSHOT` to choose another snapshot. Keep the new VPS's SSH user/key configuration; restore deliberately keeps that host access configuration from the installer.

For manual snapshot browsing and guarded restore commands, see the [Backrest and DR guide](../stacks/backrest/README.md). The Infisical encryption key and database must be restored together.

## Hardening and CrowdSec

See [HARDENING.md](HARDENING.md) for SSH, SELinux, firewalld, Docker, automatic updates, and CrowdSec behavior. The initial playbook configures CrowdSec to parse SSH authentication events from journald and installs a local nftables remediation bouncer.
