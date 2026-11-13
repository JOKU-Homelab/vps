# ComposeFlux

ComposeFlux runs the repository's Compose stacks from Git. Its canonical Compose manifest is [`stacks/composeflux/compose.yaml`](../stacks/composeflux/compose.yaml), so Renovate can update its image and ComposeFlux can reconcile its own service after a reviewed change merges.

ComposeFlux v0.19.0 supports Infisical directly. It polls the configured Git branch, reads the configured Infisical project and secret paths, and passes only referenced values to each stack's Compose configuration. The repository is intended to be public, so use an HTTPS Git URL and do not create a Git deploy key unless the repository is later made private.

## Bootstrap order

1. Ansible installs Docker and prepares the required directories and Docker network.
2. Ansible starts the `stacks/infisical` project from this repository using `/etc/vps-bootstrap/infisical.env` as the local bootstrap environment.
3. Complete Pangolin's first-admin setup and create a site. Complete Infisical's first-run setup, create a project for this VPS, add the `prod` environment, and add the secrets referenced by the stack Compose files, including `PANGOLIN_ENDPOINT`, `SITE_ID`, and `SITE_SECRET`.
4. Create a machine identity with **Viewer** access to that project and production environment. Copy its Universal Auth client ID and secret into `/etc/vps-bootstrap/composeflux.env`.
5. Ansible starts ComposeFlux from `stacks/composeflux/compose.yaml`. ComposeFlux then deploys the remaining stack directories and takes over ongoing reconciliation.

The Infisical project ID, environment name, secret path, self-hosted API URL, and repository URL are configuration, not credentials. Set them in `/etc/vps-bootstrap/composeflux.env`, alongside the machine identity credentials. The example file in this directory contains placeholders only.

Both host files must be owned by root and mode `0600`. Keep off-host recovery copies of the Infisical encryption key, authentication secret, database credentials, and ComposeFlux machine identity credential. Infisical cannot provide the initial values needed to start itself or authenticate ComposeFlux before it is running.

## Secret scope

A ComposeFlux instance uses one Infisical machine identity, project, environment, and configured secret path set for all discovered stacks. That makes the repository a shared trust boundary: any Compose file in the repo can reference a key the identity can read. Keep deployment secrets in a dedicated project and grant this identity Viewer access only. Use separate ComposeFlux instances if stacks later need isolated identities.

ComposeFlux has Docker socket access, which grants root-equivalent control of the VPS. Only merge trusted repository changes. Secrets referenced as Compose environment values may also be visible through Docker container inspection; use an application's supported `*_FILE` option or Compose secrets where possible.

## Configuration

Create `/etc/vps-bootstrap/composeflux.env` from [`.env.example`](.env.example). Set at least:

```dotenv
GIT_REPO_URL=https://github.com/OWNER/REPOSITORY.git
GIT_BRANCH=main
INFISICAL_CLIENT_ID=...
INFISICAL_CLIENT_SECRET=...
INFISICAL_ENVIRONMENT=prod
INFISICAL_PROJECT_ID=...
INFISICAL_SECRET_PATH=/
INFISICAL_SITE_URL=http://infisical-api:8080
```

`INFISICAL_SITE_URL` uses the private `pangolin_frontend` Docker network and resolves to the `infisical-api` alias in the Infisical stack. Infisical's canonical `SITE_URL` remains its public HTTPS URL, which is used for browser-facing links and callbacks.

ComposeFlux scans one directory deep under `stacks/`. Do not remove a stack directory unless you intend to stop that project; ComposeFlux removes discovered stacks deleted from Git. `PRUNE_INTERVAL=0` disables periodic Docker resource pruning, but does not disable deleted-stack reconciliation.

See the [ComposeFlux Infisical guide](https://veerendra2.github.io/composeflux/how-to-guides/Infisical/) and [overview](https://veerendra2.github.io/composeflux/Introduction/) for provider and reconciliation details.
