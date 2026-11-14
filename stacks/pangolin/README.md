# Pangolin

Ansible starts Pangolin before ComposeFlux so its Docker network and public entry point are available for the other stacks. The installer reads Pangolin's `SERVER_SECRET`, base domain, certificate email, and SMTP values from Infisical and renders the non-secret server configuration under `/opt/pangolin/config`.

Pangolin's first administrator still uses the setup token and browser wizard. After the first login, create a site for this VPS and add `PANGOLIN_ENDPOINT`, `SITE_ID`, and `SITE_SECRET` to Infisical before enabling ComposeFlux.

SMTP configuration is stored in Infisical as `SMTP_ENABLED`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM_ADDRESS`, and `SMTP_SECURE`. For Migadu's implicit TLS endpoint use port `465` and `SMTP_SECURE=true`.

The installer does not publish Pangolin secrets in a local env file. Compose runs inside an Infisical CLI process, and the Pangolin server secret and SMTP credentials are injected into the Compose process at startup.
