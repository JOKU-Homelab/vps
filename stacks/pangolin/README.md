# Pangolin

Pangolin, Gerbil, and Traefik are defined by [`compose.yaml`](compose.yaml). Renovate can propose version updates for all three images. The server and Traefik configuration templates are also tracked here; Ansible renders them under `/opt/pangolin/config` during host initialization. The site connector is defined separately in [`../pangolin-site/compose.yaml`](../pangolin-site/compose.yaml) so it can be deployed after a site has been created.

The persistent database, generated tunnel key, certificates, and runtime files are stored under `/opt/pangolin`. Compose defines the Pangolin services, and the tracked templates provide the host-rendered Pangolin and Traefik configuration.

## Initial setup

The installer asks for a base domain and certificate email, and creates `/etc/vps-bootstrap/pangolin.env` with a random `SERVER_SECRET`. It can also configure SMTP for Pangolin and Infisical. Pangolin reads its SMTP host, port, sender, and TLS mode from the rendered config and its username/password from environment variables. The first Pangolin administrator still needs the setup token and browser wizard; no supported environment-variable bootstrap is documented. Ansible starts this stack before Infisical so `pangolin_frontend` exists.

DNS should point the Pangolin dashboard and each intended public service hostname to the VPS. Open only required ports in both the provider firewall and firewalld: TCP 80/443 and the configured Gerbil UDP ports. Add an AAAA record only when IPv6 is enabled and reachable.

Pangolin prints a setup token at first startup. Complete first-admin setup through its HTTPS dashboard after DNS and certificate issuance are ready. Create a site in Pangolin. Then initialize Infisical, import the generated `/etc/vps-bootstrap/pangolin-seed.env` with the Infisical CLI, and add the site's ID and secret. Once the Infisical project and machine identity are ready, ComposeFlux can take over repository-managed stack deployments using Infisical values. Keep the root-only local bootstrap copy for recovery and pre-Infisical startup. The connector reads Compose labels through the Docker socket, so treat it as root-equivalent. Do not commit setup tokens, site credentials, license material, database files, or generated keys.

## Updates and configuration

Image updates arrive as Renovate pull requests. Pangolin releases can include database migrations, so use the Restic backup before merging a Pangolin update and follow the [official update notes](https://docs.pangolin.net/self-host/how-to-update). Keep major-version updates manual. The Badger plugin version is pinned in the tracked Traefik template and can be reviewed in the same update.

SMTP and other service credentials belong in Infisical. If Pangolin configuration needs additional secret fields, add them through supported environment variables where possible and keep the rendered runtime file out of Git. Pangolin warns that changing its server secret after startup requires the supported rotation procedure.

See the [official config reference](https://docs.pangolin.net/self-host/advanced/config-file) and the repository's [disaster-recovery guide](../backrest/README.md).
