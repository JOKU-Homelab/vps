# Ansible operations

Ansible owns host configuration and the first deployment of the core services. ComposeFlux owns ongoing application deployment after Infisical is initialized.

## Fresh VPS

Run the installer as root on a fresh AlmaLinux VPS, using a release tag:

```bash
curl -fsSL https://raw.githubusercontent.com/JOKU-Homelab/vps/main/install.sh | sudo bash -s -- --ref v1.0.0
```

The installer asks only for values missing from `/etc/vps/install.conf`; it saves each value as soon as it is accepted, so an interrupted setup can resume and later runs reuse the saved settings. An explicit partial `--config FILE` is also completed this way. A saved recovery bundle can restore the latest backup without prompts.

The installer asks whether to configure SMTP and, when enabled, collects the host, port, username, password, sender address, and TLS mode for both services. It saves each answer immediately in the protected recovery bundle. Ansible configures users, SSH, SELinux when active, firewalld, security updates, Docker, CrowdSec, backup tooling, and persistent service directories under `/opt`, then starts Pangolin and Infisical from tracked Compose files.

Neither product exposes an environment variable to create its first administrator. Pangolin's initial admin requires its setup token and web flow; Infisical's first super-admin also requires the signup UI. Complete Pangolin's setup at `https://pangolin.YOUR_BASE_DOMAIN` and create a site for this host. Infisical's setup port is bound to loopback; use an SSH tunnel from your workstation:

```bash
ssh -L 8080:127.0.0.1:18080 ADMIN_USER@YOUR_VPS_IP
```

The installer chooses a free host-side port in the `18080`–`18100` range and prints it at completion. If it chose a different port, use that number in the SSH command; it is saved as `INFISICAL_BOOTSTRAP_PORT` in `/etc/vps-bootstrap/infisical.env`. Open `http://127.0.0.1:8080` and create the first Infisical admin, a dedicated project, and a `prod` environment. The installer creates `/etc/vps-bootstrap/pangolin-seed.env` with Pangolin's `SERVER_SECRET`, endpoint, and configured SMTP values. After authenticating the Infisical CLI as an identity allowed to write project secrets, import it with `infisical secrets set --file=/etc/vps-bootstrap/pangolin-seed.env --projectId=PROJECT_ID --env=prod --path=/`. Add the Pangolin site ID/secret and each application's required values. Keep the local bootstrap copy: it lets Ansible bring up both services before Infisical is reachable and supports disaster recovery. Create a Viewer machine identity for ComposeFlux, then put its client ID and secret, the project ID, and other ComposeFlux settings in `/etc/vps-bootstrap/composeflux.env` (mode `0600`). Run:

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
