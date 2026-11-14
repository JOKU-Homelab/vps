# Service stacks

Ansible initializes the host and starts Pangolin. The installer uses Infisical for host configuration, service credentials, SMTP, and backup access. After Pangolin's first administrator and site are configured, ComposeFlux deploys and updates the repository-managed stacks.

Every service definition is stored here and can be updated through Renovate. Persistent application data is bind-mounted under `/opt`; keep data out of the repository checkout and Docker named volumes.

See [ComposeFlux and Infisical](../composeflux/README.md), [Pangolin](pangolin/README.md), and [backup/DR](backrest/README.md).
