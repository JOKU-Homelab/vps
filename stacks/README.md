# Service stacks

ComposeFlux discovers each direct child directory with a Compose file under `stacks/`. Pangolin, Infisical, ComposeFlux, and application stacks are tracked here, so Renovate can propose image updates for all of them.

Ansible installs host prerequisites and bootstraps Pangolin and Infisical. Their first admin accounts still require their web setup flows. After that, create a Pangolin site and add its credentials, `SERVER_SECRET`, and SMTP credentials to Infisical. Once Infisical's first-run setup and machine identity are complete, ComposeFlux deploys and reconciles the repository stacks—including Pangolin—using those Infisical secrets. Keep the protected local bootstrap copies for recovery and pre-Infisical startup. Keep persistent app data under `/opt`, not in the repository checkout or Docker named volumes.

## Secrets

Put application credentials in the Infisical production project. Compose files reference those variables and include no real credentials. Infisical and ComposeFlux have a small bootstrap secret set under `/etc/vps-bootstrap/`, created or entered on the host with root-only permissions. Keep off-host recovery copies of those values; they are required before Infisical can serve any other secret.

ComposeFlux uses one machine identity across the repository's discovered stacks. Treat every committed Compose file as trusted code with access to the identity's configured secret paths. Compose environment variables can be visible through container inspection; use supported `*_FILE` options or Compose secrets where services allow them.

## Pangolin resource discovery

Web services intended for public access declare Pangolin resource labels on their Compose service. The Pangolin stack owns the external `pangolin_frontend` network; routed application services join that network. Enable Pangolin SSO for public resources where supported and document narrow path exceptions only when an application protocol requires them.

The repository-managed Pangolin CLI site connector reads those labels through `/var/run/docker.sock`, which grants root-equivalent access. Store `PANGOLIN_ENDPOINT`, `SITE_ID`, and `SITE_SECRET` in Infisical before enabling ComposeFlux. For an existing installation, stop the old connector after confirming the restored Pangolin site credentials work with this service.

ComposeFlux removes a stack when its Compose project is deleted from Git. Preserve application data under `/opt` and take a backup before retiring a stack. Do not remove directories from this tree casually.

See [Infisical](infisical/README.md), [ComposeFlux](../composeflux/README.md), [Pangolin](pangolin/README.md), [the Pangolin site connector](pangolin-site/README.md), and [backup/DR](backrest/README.md) for service-specific setup.
