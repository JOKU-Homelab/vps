# VPS hardening baseline

This is the repository's baseline for a single AlmaLinux VPS. It is a practical configuration, not a claim of CIS compliance.

## Managed controls

- **SSH:** public-key authentication only; root login, password authentication, agent forwarding, X11 forwarding, and tunnel devices are disabled. TCP local forwarding remains available for admin tunnels. `MaxAuthTries` is 5 and login grace is 30 seconds. The allowed account list comes from local bootstrap configuration; the Ansible service key is constrained against TTY and forwarding.
- **SELinux:** targeted policy is enforcing. The playbook stops if SELinux is disabled because enabling it safely requires a planned relabel and reboot.
- **Host firewall:** firewalld is enabled. SSH, Pangolin web traffic, and the selected Pangolin tunnel ports are allowed. Docker-published ports need a separate review because Docker manages forwarding rules.
- **Updates:** DNF Automatic installs security updates but does not reboot automatically. Schedule maintenance for kernel and service restarts.
- **Docker:** installed from Docker's official RPM repository, with live restore and rotating local logs. Docker group membership and ComposeFlux's Docker socket are root-equivalent access.
- **CrowdSec:** the Security Engine reads SSH authentication events from journald, installs the SSH collection, and applies local decisions through an nftables firewall bouncer. Verify acquisition and bouncer health after deployment; add an HTTP-layer bouncer if a future reverse-proxy design requires one.
- **Backups:** Restic snapshots and restore helpers are installed by Ansible. The daily timer remains disabled until root-only object-storage and repository-password files exist.

CrowdSec requires a remediation component to enforce its decisions; the firewall bouncer is configured for host-level blocking. See [CrowdSec's installation guide](https://docs.crowdsec.net/u/getting_started/installation/linux/) and [firewall bouncer guide](https://docs.crowdsec.net/u/bouncers/firewall/).

## Apply to an existing host

For a new VPS, use the repository's installer. For an existing host, configure a local inventory with its address and key, then run:

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory/production.local.yml playbooks/configure-vps.yml
```

Before applying SSH or firewall changes, confirm key-based access for the configured admin account and keep the current session and provider console available. The SSH role validates syntax and effective settings before restarting the SSH daemon.

## Operational review

- Review the host and provider firewall rules before exposing a port.
- Review every Compose `ports:` mapping; bind administration-only interfaces to loopback.
- Do not expose the Docker API over TCP.
- Check CrowdSec acquisition metrics and confirm its bouncer is connected to the local API.
- Keep Infisical's bootstrap credentials and encryption key outside Git; back them up off-host.
- Keep image updates moving through Renovate PRs and review major updates manually.
- Run backup checks and restore drills. See the [DR guide](../stacks/backrest/README.md).

## References

- [RHEL 10 security hardening](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/security_hardening/)
- [RHEL 10 OpenSSH guidance](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/securing_networks/using-secure-communications-between-two-systems-with-openssh)
- [Docker firewall with iptables](https://docs.docker.com/engine/network/firewall-iptables/)
- [Docker port publishing](https://docs.docker.com/engine/network/port-publishing/)
- [CrowdSec Linux installation](https://docs.crowdsec.net/u/getting_started/installation/linux/)
- [CrowdSec journald acquisition](https://docs.crowdsec.net/docs/log_processor/data_sources/journald/)
