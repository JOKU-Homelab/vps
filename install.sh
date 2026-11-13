#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly REPOSITORY_URL="https://github.com/JOKU-Homelab/vps.git"
readonly DEFAULT_REF="main"
readonly INSTALL_ROOT="/opt/vps"
readonly BOOTSTRAP_DIR="/etc/vps-bootstrap"
readonly CONFIG_PATH="/etc/vps/install.conf"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root, for example: curl -fsSL https://raw.githubusercontent.com/JOKU-Homelab/vps/main/install.sh | sudo bash"
[[ -r /etc/os-release ]] || die "Cannot identify this operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == almalinux || "${ID_LIKE:-}" == *rhel* ]] || die "This installer currently supports AlmaLinux/RHEL-family hosts only."

ref="${VPS_REF:-$DEFAULT_REF}"
ref_override="${VPS_REF:-}"
restore_snapshot="${VPS_RESTORE_SNAPSHOT:-}"
restore_override="$restore_snapshot"
config_file=""
config_mode=false
repo_dir="$INSTALL_ROOT/repo"
while (($#)); do
  case "$1" in
    --ref) (($# >= 2)) || die "--ref needs a tag or branch"; ref="$2"; ref_override="$2"; shift 2 ;;
    --restore) (($# >= 2)) || die "--restore needs a snapshot ID or latest"; restore_snapshot="$2"; restore_override="$2"; shift 2 ;;
    --config) (($# >= 2)) || die "--config needs a path to install.conf"; config_file="$2"; shift 2 ;;
    -h|--help)
      cat <<'USAGE'
Usage: install.sh [--config FILE] [--ref TAG_OR_BRANCH] [--restore SNAPSHOT]

Run as root on a fresh AlmaLinux/RHEL VPS. With no config, the installer asks
for host settings and backup credentials, then writes /etc/vps/install.conf.
Keep a protected copy of that file. On a replacement VPS, pass it with
--config; the installer restores the latest snapshot without prompts.

The config file contains recovery secrets. Protect it as you would a password
vault export. Use --restore to select another snapshot during recovery.
USAGE
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

info "Installing Git, Python, Ansible, and OpenSSL"
dnf install -y git python3 ansible-core openssl

if [[ -n "$config_file" ]]; then
  [[ -f "$config_file" && -r "$config_file" ]] || die "Cannot read config file: $config_file"
  config_mode=true
  eval "$(python3 - "$config_file" <<'PY'
import json, pathlib, shlex, sys
p = pathlib.Path(sys.argv[1])
try:
    c = json.loads(p.read_text())
except Exception as e:
    raise SystemExit(f"invalid install.conf: {e}")
if c.get("schema_version") != 1:
    raise SystemExit("unsupported install.conf schema_version")
required = ("repository_url", "ref", "admin_user", "admin_ssh_public_key", "base_domain", "admin_email", "restore_snapshot")
for key in required:
    if not isinstance(c.get(key), str) or not c[key]:
        raise SystemExit(f"install.conf is missing {key}")
for key in required:
    print(f"{key}={shlex.quote(c[key])}")
PY
  )" || die "Could not load install.conf"
  [[ "$repository_url" == https://* ]] || die "install.conf repository_url must use HTTPS"
  ref="${ref_override:-$ref}"
  if [[ -n "$restore_override" ]]; then restore_snapshot="$restore_override"
  else restore_snapshot="${restore_snapshot:-latest}"; fi
  # Materialize the protected bootstrap files from the bundle, never by sourcing it.
  python3 - "$config_file" <<'PY'
import json, pathlib, os
c = json.loads(pathlib.Path(__import__('sys').argv[1]).read_text())
bootstrap = c.get("bootstrap")
if not isinstance(bootstrap, dict): raise SystemExit("install.conf is missing bootstrap recovery data")
for directory in ("/etc/vps-bootstrap", "/etc/vps"):
    p = pathlib.Path(directory); p.mkdir(mode=0o700, parents=True, exist_ok=True); p.chmod(0o700); os.chown(p, 0, 0)
files = {
    "/etc/vps-bootstrap/site.yml": c.get("site_yaml"),
    "/etc/vps-bootstrap/infisical.env": bootstrap.get("infisical_env"),
    "/etc/vps-bootstrap/pangolin.env": bootstrap.get("pangolin_env"),
    "/etc/vps-bootstrap/composeflux.env": bootstrap.get("composeflux_env"),
    "/etc/vps/backup.env": bootstrap.get("backup_env"),
    "/etc/vps/restic-password": bootstrap.get("restic_password"),
}
if any(not isinstance(v, str) or not v for v in files.values()):
    raise SystemExit("install.conf is missing one or more bootstrap/backup files")
for name, content in files.items():
    p = pathlib.Path(name); p.write_text(content.rstrip("\n") + "\n"); p.chmod(0o600); os.chown(p, 0, 0)
source = pathlib.Path(__import__('sys').argv[1]).resolve()
destination = pathlib.Path('/etc/vps/install.conf')
destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
if source != destination.resolve(): destination.write_bytes(source.read_bytes())
destination.chmod(0o600); os.chown(destination, 0, 0)
PY
else
  repository_url="$REPOSITORY_URL"
  admin_user="${VPS_ADMIN_USER:-}"
  admin_ssh_public_key="${VPS_ADMIN_SSH_KEY:-}"
  base_domain="${VPS_BASE_DOMAIN:-}"
  admin_email="${VPS_ADMIN_EMAIL:-}"
  [[ -t 0 || -r /dev/tty ]] || die "An interactive terminal is required for first-time setup; use --config FILE for unattended restore."
  prompt() {
    local var_name="$1" label="$2" default_value="${3:-}" value=""
    [[ -n "${!var_name:-}" ]] && return
    if [[ -n "$default_value" ]]; then read -r -p "$label [$default_value]: " value </dev/tty; value="${value:-$default_value}"
    else read -r -p "$label: " value </dev/tty; fi
    [[ -n "$value" ]] || die "$label is required."
    printf -v "$var_name" '%s' "$value"
  }
  prompt admin_user "Administrator login name" "admin"
  prompt admin_ssh_public_key "Administrator SSH public key (single line)"
  prompt base_domain "Base domain for public services"
  prompt admin_email "Administrator/ACME email address"
fi

[[ "$admin_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Invalid Linux username."
[[ "$admin_ssh_public_key" == ssh-ed25519\ * || "$admin_ssh_public_key" == ecdsa-sha2-nistp*\ * || "$admin_ssh_public_key" == ssh-rsa\ * ]] || die "The SSH key does not look like a supported public key."
[[ "$base_domain" =~ ^[A-Za-z0-9.-]+$ ]] || die "Enter a domain name without a scheme or path."
[[ "$admin_email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "Enter a valid email address."
[[ -z "$restore_snapshot" || "$restore_snapshot" =~ ^(latest|[A-Fa-f0-9]{4,64})$ ]] || die "Snapshot must be 'latest' or a hexadecimal Restic snapshot ID."

export repository_url ref admin_user admin_ssh_public_key base_domain admin_email

if [[ "$config_mode" == false ]]; then
  [[ -r /dev/tty ]] || die "First-time setup requires a terminal."
  info "Collecting off-host backup credentials"
  read -r -p "Restic repository (for example b2:bucket-name:/vps): " RESTIC_REPOSITORY </dev/tty
  read -r -p "Backblaze B2 account ID: " B2_ACCOUNT_ID </dev/tty
  read -r -s -p "Backblaze B2 application key: " B2_ACCOUNT_KEY </dev/tty; printf '\n' >/dev/tty
  read -r -s -p "Restic repository password: " RESTIC_PASSWORD </dev/tty; printf '\n' >/dev/tty
  [[ "$RESTIC_REPOSITORY" =~ ^[A-Za-z0-9:/._@+-]+$ ]] || die "Repository URL contains unsupported characters."
  [[ "$B2_ACCOUNT_ID" =~ ^[A-Za-z0-9_-]+$ && "$B2_ACCOUNT_KEY" =~ ^[A-Za-z0-9_-]+$ ]] || die "B2 credentials contain unsupported characters."
  [[ -n "$RESTIC_PASSWORD" ]] || die "Restic repository password is required."
  export RESTIC_REPOSITORY B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_PASSWORD
fi

info "Fetching repository ref $ref"
install -d -o root -g root -m 0755 "$INSTALL_ROOT"
if [[ -d "$repo_dir/.git" ]]; then
  git -C "$repo_dir" fetch --depth 1 origin "$ref"
  git -C "$repo_dir" checkout --force FETCH_HEAD
else
  git clone --depth 1 --branch "$ref" "$repository_url" "$repo_dir" || git clone --depth 1 "$repository_url" "$repo_dir"
  [[ "$ref" == "$DEFAULT_REF" ]] || git -C "$repo_dir" checkout --detach "$ref"
fi

if [[ "$config_mode" == false ]]; then
  install -d -o root -g root -m 0700 "$BOOTSTRAP_DIR" /etc/vps
  python3 - <<'PY'
import json, os, pathlib, secrets, base64
boot = pathlib.Path('/etc/vps-bootstrap'); boot.mkdir(mode=0o700, parents=True, exist_ok=True)
def write_env(path, values):
    path.write_text(''.join(f'{k}={v}\n' for k,v in values.items())); path.chmod(0o600)
if not (boot/'infisical.env').exists():
    key=secrets.token_hex(16); auth=base64.b64encode(secrets.token_bytes(32)).decode()
    pg=secrets.token_hex(32); red=secrets.token_hex(32); domain=os.environ['base_domain']
    write_env(boot/'infisical.env', {'ENCRYPTION_KEY':key,'AUTH_SECRET':auth,'POSTGRES_USER':'infisical','POSTGRES_PASSWORD':pg,'POSTGRES_DB':'infisical','DB_CONNECTION_URI':f'postgresql://infisical:{pg}@db:5432/infisical','REDIS_PASSWORD':red,'REDIS_URL':f'redis://:{red}@redis:6379/0','SITE_URL':f'https://infisical.{domain}','INFISICAL_PUBLIC_DOMAIN':f'infisical.{domain}'})
if not (boot/'pangolin.env').exists():
    domain=os.environ['base_domain']; email=os.environ['admin_email']
    write_env(boot/'pangolin.env', {'SERVER_SECRET':base64.b64encode(secrets.token_bytes(48)).decode(),'BASE_DOMAIN':domain,'PANGOLIN_DOMAIN':f'pangolin.{domain}','LETSENCRYPT_EMAIL':email,'INFISICAL_PUBLIC_DOMAIN':f'infisical.{domain}'})
if not (boot/'composeflux.env').exists():
    write_env(boot/'composeflux.env', {'GIT_REPO_URL':os.environ['repository_url'],'GIT_BRANCH':os.environ['ref'],'INFISICAL_SITE_URL':'http://infisical-api:8080','INFISICAL_ENVIRONMENT':'prod','INFISICAL_PROJECT_ID':'SET_AFTER_INFISICAL_SETUP','INFISICAL_CLIENT_ID':'SET_AFTER_INFISICAL_SETUP','INFISICAL_CLIENT_SECRET':'SET_AFTER_INFISICAL_SETUP','INFISICAL_SECRET_PATH':'/'})
backup=pathlib.Path('/etc/vps/backup.env')
backup.write_text(f"RESTIC_REPOSITORY={os.environ['RESTIC_REPOSITORY']}\nB2_ACCOUNT_ID={os.environ['B2_ACCOUNT_ID']}\nB2_ACCOUNT_KEY={os.environ['B2_ACCOUNT_KEY']}\n")
backup.chmod(0o600); pathlib.Path('/etc/vps/restic-password').write_text(os.environ['RESTIC_PASSWORD']+'\n'); pathlib.Path('/etc/vps/restic-password').chmod(0o600)
site={'vps_base_domain':os.environ['base_domain'],'vps_admin_email':os.environ['admin_email'],'vps_users':[{'name':os.environ['admin_user'],'comment':'VPS administrator','shell':'/bin/bash','groups':['wheel','docker'],'public_key':os.environ['admin_ssh_public_key'],'passwordless_sudo':True},{'name':'ansible','comment':'Ansible service account','shell':'/bin/bash','groups':['wheel'],'public_key':os.environ['admin_ssh_public_key'],'key_options':'no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding','passwordless_sudo':True}]}
(boot/'site.yml').write_text(json.dumps(site,indent=2)+'\n'); (boot/'site.yml').chmod(0o600)
PY
  chmod 0600 "$BOOTSTRAP_DIR"/*.env "$BOOTSTRAP_DIR/site.yml" /etc/vps/backup.env /etc/vps/restic-password
  export repository_url ref admin_user admin_ssh_public_key base_domain admin_email RESTIC_REPOSITORY B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_PASSWORD
  python3 - "$CONFIG_PATH" <<'PY'
import json, os, pathlib, sys
def read(path): return pathlib.Path(path).read_text()
c={'schema_version':1,'repository_url':os.environ['repository_url'],'ref':os.environ['ref'],'restore_snapshot':'latest','admin_user':os.environ['admin_user'],'admin_ssh_public_key':os.environ['admin_ssh_public_key'],'base_domain':os.environ['base_domain'],'admin_email':os.environ['admin_email'],'site_yaml':read('/etc/vps-bootstrap/site.yml'),'bootstrap':{'infisical_env':read('/etc/vps-bootstrap/infisical.env'),'pangolin_env':read('/etc/vps-bootstrap/pangolin.env'),'composeflux_env':read('/etc/vps-bootstrap/composeflux.env'),'backup_env':read('/etc/vps/backup.env'),'restic_password':read('/etc/vps/restic-password').rstrip('\n')}}
p=pathlib.Path(sys.argv[1]); p.parent.mkdir(mode=0o700,parents=True,exist_ok=True); p.write_text(json.dumps(c,indent=2)+'\n'); p.chmod(0o600); os.chown(p,0,0)
PY
  unset B2_ACCOUNT_KEY RESTIC_PASSWORD
fi

info "Installing Ansible collections and initializing the host"
export ANSIBLE_CONFIG="$repo_dir/ansible/ansible.cfg"
ansible-galaxy collection install -r "$repo_dir/ansible/requirements.yml"
ansible_extra_vars=(--extra-vars "@$BOOTSTRAP_DIR/site.yml")
if [[ -n "$restore_snapshot" ]]; then ansible_extra_vars+=(--extra-vars "vps_restore_snapshot=$restore_snapshot")
else ansible_extra_vars+=(--extra-vars 'vps_init_backup=true'); fi
ansible-playbook -i 'localhost,' -c local "$repo_dir/ansible/playbooks/initialize-vps.yml" "${ansible_extra_vars[@]}"
if [[ -z "$restore_snapshot" ]]; then /usr/local/sbin/vps-backup init; fi

if [[ -n "$restore_snapshot" ]] && ! grep -q 'SET_AFTER_INFISICAL_SETUP' "$BOOTSTRAP_DIR/composeflux.env"; then
  ansible-playbook -i 'localhost,' -c local "$repo_dir/ansible/playbooks/enable-gitops.yml"
fi
cat <<DONE

Initialization finished. Recovery bundle: $CONFIG_PATH (root-only mode 0600).
Keep a protected copy off-server. A replacement VPS can be initialized without
prompts using install.sh --config /path/to/install.conf.
DONE
