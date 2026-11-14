# ComposeFlux and Infisical

ComposeFlux deploys repository-managed Compose projects after Pangolin's first-run setup. It reads the configured Infisical project and injects secrets into each stack during deployment.

The installer starts ComposeFlux only after the operator creates a Pangolin site and stores its endpoint, site ID, and site secret in Infisical. This avoids starting the managed stacks before their required configuration exists.

## Infisical settings

ComposeFlux uses a dedicated read-only Universal Auth identity stored in `/etc/vps-bootstrap/composeflux.env` (root:root, mode `0600`). The installer uses a separate bootstrap identity for setup and backups, which should also be read-only after initial project seeding. Cloud is the default endpoint; a self-hosted instance can be selected with its HTTPS URL.

ComposeFlux receives its Infisical endpoint, project ID, environment, path, and Git repository settings from the bootstrap environment and Infisical values. Keep the project limited to the secrets required by this repository because ComposeFlux can deploy any trusted Compose file in its managed Git checkout and has Docker socket access.

## Required stack values

The installer seeds generated credentials and placeholder values. Complete the `CHANGE_ME` values in Infisical before continuing. Compose files declare required keys with Compose interpolation errors, so missing configuration fails visibly rather than silently deploying with empty credentials.

Pangolin's first administrator and site are created through its UI. There is no environment-variable first-admin bootstrap. Then add `PANGOLIN_ENDPOINT`, `SITE_ID`, and `SITE_SECRET` to Infisical and continue the installer.

For CLI use, Universal Auth follows Infisical's documented machine identity flow:

```bash
export INFISICAL_DOMAIN=https://eu.infisical.com
export INFISICAL_TOKEN="$(infisical login --method=universal-auth \
  --client-id="$INFISICAL_CLIENT_ID" \
  --client-secret="$INFISICAL_CLIENT_SECRET" --silent --plain)"
infisical run --token="$INFISICAL_TOKEN" --projectId="$INFISICAL_PROJECT_ID" \
  --env=prod --path=/ -- docker compose up -d
```

Omit the default domain override only when using Infisical Cloud's default endpoint. For regional Cloud or self-hosted endpoints, use the URL shown by that Infisical instance.

See the [ComposeFlux documentation](https://veerendra2.github.io/composeflux/) and the [Infisical Universal Auth guide](https://infisical.com/blog/introducing-machine-identities).
