# Pangolin site connector

This Compose project runs the Pangolin CLI site connector with Docker label discovery enabled. Its image is versioned in [`compose.yaml`](compose.yaml) and can be updated through Renovate.

## Setup

Create the Pangolin site after the dashboard's first-admin setup. Add `PANGOLIN_ENDPOINT`, `SITE_ID`, and `SITE_SECRET` from the site configuration to `/pangolin-site` in the Infisical project and environment used by ComposeFlux. The endpoint should be `https://pangolin.<base-domain>`. ComposeFlux starts this service after its Infisical identity is configured.

The connector mounts `/var/run/docker.sock` so it can discover labels. Docker socket access grants root-equivalent control of the VPS. Only merge trusted repository changes and restrict the ComposeFlux machine identity to the one deployment project.

For a migration, first ensure the restored Pangolin database contains the site that owns these credentials, then stop any old connector before ComposeFlux starts this one. See Pangolin's [site connector guide](https://docs.pangolin.net/manage/sites/install-site) and [Docker label discovery guide](https://docs.pangolin.net/manage/blueprints).
