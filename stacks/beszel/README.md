# Beszel

Beszel Hub stores its data in `/opt/vps/data/beszel` and joins Pangolin's `pangolin_frontend` network. Its Compose labels create a Pangolin resource at the domain configured through Infisical.

The Hub's initial account setup port is loopback-only. Forward it from your workstation:

```bash
ssh -L 8090:127.0.0.1:8090 ADMIN_USER@YOUR_VPS_IP
```

Open `http://127.0.0.1:8090` and create the first account. Do not expose the setup interface on a public host port. The Hub has no Compose secret values; SMTP settings added through the PocketBase admin UI are stored in the app database and included in host snapshots.

Beszel agents authenticate at the WebSocket endpoint allowed by the Pangolin resource policy. Hub data is bind-mounted at `/opt/vps/data/beszel` for direct backup and restore.

Beszel's SMTP configuration is separate from its alert channels. See [account email settings](https://beszel.dev/guide/user-accounts) and [notification channels](https://beszel.dev/guide/notifications/).
