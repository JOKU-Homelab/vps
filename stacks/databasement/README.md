# Databasement

Databasement manages database backup jobs. Its SQLite application database is stored in `/opt/vps/data/databasement`; configured dumps are written to `/opt/vps/data/database-backups`.

The stack joins Pangolin's frontend network for the web route and an isolated `vps_database_backups` network for database connectivity. Database services should join only the isolated backup network with stable aliases; do not publish database ports on the Pangolin network.

## Infisical values

Add Databasement values listed in [`.env.example`](.env.example) to `/databasement`; shared SMTP values belong in `/smtp`. `APP_KEY` and OIDC client credentials are secrets. URLs, domains, and the backup path are deployment configuration values. Do not commit a live `.env` file.

## First setup

After ComposeFlux deploys the stack, open `https://databasement.<base-domain>` and create the administrator account. In the UI, add a local storage volume at `/backups`, register database servers on the isolated backup network, and configure backup schedules and retention.

Databasement's SQLite database and its generated dumps are covered by the host snapshot. A live SQLite file copy can be crash-consistent; export or briefly stop the service before a planned restore if application-level consistency is required.

## Authentik OIDC

Create an OAuth2/OpenID Connect application in Authentik with the callback URI `https://databasement.<base-domain>/oauth/oidc/callback`. Store its client ID and secret in the corresponding Infisical values. Set the OIDC base URL to `https://authentik.<base-domain>/application/o/databasement/`.

Keep password login enabled until the OIDC flow has been tested. With auto-create disabled, the OIDC email must match an existing Databasement account. See the [Databasement SSO guide](https://david-crty.github.io/databasement/self-hosting/configuration/sso/).

## Email delivery

Set the SMTP host, port, username, password, and sender address in Infisical `/smtp`. The Compose file uses implicit TLS. See the [notification guide](https://david-crty.github.io/databasement/self-hosting/configuration/notification/).
