# Renovate

Renovate scans the repository's Compose manifests and opens pull requests for image updates. The self-hosted service runs continuously; its repository and fine-grained GitHub token are read from the Infisical `/renovate` folder.

Create a fine-grained token scoped to this repository and grant Renovate's documented permissions: **Contents: read and write**, **Pull requests: read and write**, **Commit statuses: read and write**, **Issues: read and write**, **Dependabot alerts: read**, and **Workflows: read and write**. Grant **Members: read** at organization level when applicable. Store `RENOVATE_REPOSITORIES` and `RENOVATE_TOKEN` in `/renovate`. Keep the write token separate from ComposeFlux's read-only HTTPS access.

## Automerge

The repository config enables GitHub platform automerge for Renovate minor and patch updates. Major updates remain manual. GitHub must have **Allow auto-merge** enabled under Settings → General → Pull Requests. The `compose-config` GitHub Actions check validates every tracked Compose file and is available as a required branch protection check. GitHub merges an eligible PR after all required checks and review rules pass; automerge does not bypass required human reviews. Renovate also needs the token permissions above and permission to create and update pull requests.

After merging, check the Renovate dashboard/logs and a minor or patch PR to confirm the repository setting, token, and branch rules work together. Configuration alone cannot enable the GitHub repository setting.

See [Renovate automerge](https://docs.renovatebot.com/key-concepts/automerge/) and [GitHub token permissions](https://docs.renovatebot.com/modules/platform/github/).
