# Authentik

Authentik provides OIDC identity for Pangolin and other applications. Its PostgreSQL database and persistent data, certificate, and template directories are bind-mounted under `/opt/vps/data/authentik/`. PostgreSQL also joins the isolated `vps_database_backups` network so database exports can be made without publishing a database port.

Authentik is intentionally not protected by Pangolin Platform SSO; an identity provider cannot require itself to authenticate. Protect the local admin account with a strong password and MFA.

## Infisical values

Add `PG_*` and `AUTHENTIK_*` values listed in [`.env.example`](.env.example) to `/authentik`; shared SMTP values belong in `/smtp`. Generate unique values for `PG_PASS` and `AUTHENTIK_SECRET_KEY`. Do not create or commit a plaintext env file.

## First login

After ComposeFlux deploys the stack, open `https://authentik.<base-domain>/if/flow/initial-setup/` and create the first administrator password. Create a named administrator account and enable MFA.

## Connect Authentik to Pangolin

1. In Authentik, create an OAuth2/OpenID Connect application and provider for Pangolin.
2. Copy the client ID and secret into the matching Infisical keys.
3. In Pangolin, add Authentik as an OIDC identity provider. Use the Authentik application endpoints under `https://authentik.<base-domain>/application/o/`.
4. Copy the callback URL Pangolin displays into the Authentik provider's redirect URI.
5. Test in a private browser window and retain a working local Pangolin admin session until login succeeds.

## Database backups

The Restic job exports PostgreSQL containers to a temporary SQL dump before making a snapshot. Authentik's database is the primary restore source; restore its SQL dump into the matching PostgreSQL version before bringing Authentik back online. The filesystem copy of a live database volume is not a substitute for the logical export. See [Authentik's backup guide](https://docs.goauthentik.io/sys-mgmt/ops/backup-restore/) and the repository [DR guide](../backrest/README.md).

## Email

Configure the SMTP server, username, password, sender address, and port in Infisical `/smtp`. Authentik uses SSL for implicit TLS and disables STARTTLS in this Compose configuration. Keep email credentials out of the repository.
