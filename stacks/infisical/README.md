# Infisical

This stack self-hosts Infisical with PostgreSQL and Redis. The Compose definition is tracked here so Renovate can propose image updates and ComposeFlux can deploy reviewed changes. PostgreSQL and the Infisical encryption key are essential recovery data; Redis is a cache and can be rebuilt.

## First deployment

Ansible creates the `pangolin_frontend` Docker network, installs the root-only bootstrap file at `/etc/vps-bootstrap/infisical.env`, and starts this Compose project from the repository. The public Infisical URL is supplied by the local deployment configuration and must match `INFISICAL_PUBLIC_DOMAIN` in the bootstrap file.

The file must contain the keys in [`bootstrap.env.example`](bootstrap.env.example), with generated values. The installer can add the optional `SMTP_*` settings to this file for transactional mail. Infisical's first super-admin account is created through the signup UI; no supported first-admin environment bootstrap is documented. Create and retain secure off-host copies of `ENCRYPTION_KEY`, `AUTH_SECRET`, `POSTGRES_PASSWORD`, and `REDIS_PASSWORD`. Losing `ENCRYPTION_KEY` makes the secrets stored in the Infisical database unrecoverable. The PostgreSQL database and its encryption key must be backed up together.

Before the identity provider is deployed, the Pangolin SSO route may not be usable. The stack binds its setup port only to host loopback. The installer selects a free host port in `18080`–`18100` and stores it as `INFISICAL_BOOTSTRAP_PORT` in `/etc/vps-bootstrap/infisical.env`; the container still listens on `8080`. Forward the selected host port over SSH, open `http://127.0.0.1:8080`, and complete the first-run account setup. The installer prints the selected port; it is also available with `grep INFISICAL_BOOTSTRAP_PORT /etc/vps-bootstrap/infisical.env`. Do not change the host bind to `0.0.0.0` or publish it publicly. Once the identity provider and SSO route are ready, remove the loopback mapping in a reviewed commit and use the Pangolin route.

## Configure ComposeFlux access

In Pangolin, create a site for the VPS and save its site ID and secret. In Infisical, create a dedicated project for this VPS and a `prod` environment. Add the Pangolin `SERVER_SECRET`, SMTP credentials, and the keys used by the Compose files, including `PANGOLIN_ENDPOINT`, `SITE_ID`, `SITE_SECRET`, and `INFISICAL_PUBLIC_DOMAIN`. Use a restricted secret path if practical. Then create a machine identity with Viewer access to this project and environment, configure Universal Auth, and put its client credentials in `/etc/vps-bootstrap/composeflux.env`.

Use the tracked `*.env.example` files as per-stack key inventories. Set the Infisical and Pangolin bootstrap values from their root-only files, add the app credentials listed by Authentik and Databasement, then add the Renovate token, and domain/port settings for Beszel and Backrest. Keep the backup storage credentials in Infisical as the source of truth and install a root-only local copy for the host backup timer as documented in [Backrest and disaster recovery](../backrest/README.md).

ComposeFlux uses one machine identity and configured secret path set for all stacks. Keep this project limited to the secrets needed by this repository. Any trusted Compose file in the repository can reference those values. The ComposeFlux API endpoint is `http://infisical-api:8080` on the private Docker network; `SITE_URL` is the public HTTPS address used by Infisical's browser interface.

For setup details, see the [Infisical self-hosting guide](https://infisical.com/videos/self-host-infisical) and the [ComposeFlux Infisical guide](https://veerendra2.github.io/composeflux/how-to-guides/Infisical/).
