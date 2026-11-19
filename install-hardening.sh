#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly REPOSITORY_URL_DEFAULT="https://github.com/JOKU-Homelab/vps.git"
readonly INSTALL_ROOT="/opt/vps"
readonly BOOTSTRAP_DIR="/etc/vps-bootstrap"
repo_dir="$INSTALL_ROOT/repo"
config_file="$BOOTSTRAP_DIR/init.json"

info() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --config) (($# >= 2)) || die "--config needs a JSON file path"; config_file="$2"; shift 2 ;;
    -h|--help)
      cat <<'USAGE'
Usage: install-hardening.sh [--config PATH]

Applies host access, SSH, firewall, CrowdSec, and automatic security-update
hardening on AlmaLinux/RHEL. It does not install Docker or deploy application
stacks. The local JSON config is created or updated as values are entered.
USAGE
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || die "Run this script as root."
[[ -r /etc/os-release ]] || die "Cannot identify this operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == almalinux || "${ID_LIKE:-}" == *rhel* ]] || die "This installer supports AlmaLinux/RHEL-family hosts only."

info "Installing Ansible prerequisites"
dnf install -y git python3 ansible-core openssl curl

install -d -o root -g root -m 0700 "$BOOTSTRAP_DIR" "$INSTALL_ROOT"
config_file="$(realpath -m "$config_file")"
install -d -o root -g root -m 0700 "$(dirname "$config_file")"
if [[ -e "$config_file" ]]; then
  python3 - "$config_file" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])
try:
    value=json.loads(p.read_text())
except Exception as exc:
    raise SystemExit(f"Invalid JSON config {p}: {exc}")
if not isinstance(value, dict):
    raise SystemExit(f"JSON config {p} must contain an object")
PY
  chown root:root "$config_file"
  chmod 0600 "$config_file"
else
  install -o root -g root -m 0600 /dev/null "$config_file"
  printf '{}\n' >"$config_file"
fi

save_config_value() {
  local key="$1" value="$2"
  INIT_CONFIG_KEY="$key" INIT_CONFIG_VALUE="$value" python3 - "$config_file" <<'PY'
import json, os, pathlib, tempfile, sys
p=pathlib.Path(sys.argv[1])
data=json.loads(p.read_text()) if p.exists() and p.stat().st_size else {}
data[os.environ['INIT_CONFIG_KEY']]=os.environ['INIT_CONFIG_VALUE']
fd,tmp=tempfile.mkstemp(prefix='.init.json.', dir=p.parent)
try:
    with os.fdopen(fd,'w') as out: json.dump(data,out,indent=2); out.write('\n')
    os.chmod(tmp,0o600); os.chown(tmp,0,0); os.replace(tmp,p)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
}

get_config_value() {
  INIT_CONFIG_KEY="$1" python3 - "$config_file" <<'PY'
import json, os, pathlib, sys
p=pathlib.Path(sys.argv[1])
try: data=json.loads(p.read_text())
except Exception: data={}
value=data.get(os.environ['INIT_CONFIG_KEY'], '')
if isinstance(value, str): print(value)
PY
}

prompt_config_value() {
  local key="$1" label="$2" default_value="${3:-}" value
  value="${!key:-}"
  [[ -n "$value" ]] || value="$(get_config_value "$key")"
  if [[ -z "$value" ]]; then
    IFS= read -r -p "$label${default_value:+ [$default_value]}: " value </dev/tty || die "Could not read $label."
    value="${value:-$default_value}"
  fi
  [[ -n "$value" ]] || die "$label is required."
  printf -v "$key" '%s' "$value"
  save_config_value "$key" "$value"
}

prompt_config_value VPS_ADMIN_USER "Linux admin username" "admin"
prompt_config_value VPS_ADMIN_SSH_PUBLIC_KEY "Admin SSH public key"
[[ "$VPS_ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "VPS_ADMIN_USER is not a valid Linux username."
[[ "$VPS_ADMIN_SSH_PUBLIC_KEY" == ssh-ed25519\ * || "$VPS_ADMIN_SSH_PUBLIC_KEY" == ecdsa-sha2-nistp*\ * || "$VPS_ADMIN_SSH_PUBLIC_KEY" == ssh-rsa\ * ]] || die "VPS_ADMIN_SSH_PUBLIC_KEY must be an SSH public key."

repository_url="$REPOSITORY_URL_DEFAULT"
ref="${VPS_INSTALL_REF:-main}"
info "Fetching repository ref $ref"
if [[ -d "$repo_dir/.git" ]]; then
  git -C "$repo_dir" fetch --depth 1 origin "$ref"
  git -C "$repo_dir" checkout --force FETCH_HEAD
else
  git clone --depth 1 --branch "$ref" "$repository_url" "$repo_dir"
fi

export ANSIBLE_CONFIG="$repo_dir/ansible/ansible.cfg"
info "Installing the hardening playbook collections"
ansible-galaxy collection install -r "$repo_dir/ansible/requirements-hardening.yml"

vars_file="$(mktemp /run/vps-hardening.XXXXXX.json)"
trap 'rm -f "${vars_file:-}"' EXIT
INIT_ADMIN_USER="$VPS_ADMIN_USER" INIT_ADMIN_KEY="$VPS_ADMIN_SSH_PUBLIC_KEY" python3 - "$vars_file" <<'PY'
import json, os, sys
admin=os.environ['INIT_ADMIN_USER']
key=os.environ['INIT_ADMIN_KEY']
vars={
  "ansible_admin_group":"wheel",
  "vps_create_docker_group":False,
  "vps_open_pangolin_ports":False,
  "vps_users":[
    {"name":admin,"comment":"VPS administrator","shell":"/bin/bash","groups":["wheel"],"public_key":key,"passwordless_sudo":True},
    {"name":"ansible","comment":"Ansible automation account","shell":"/bin/bash","groups":["wheel"],"public_key":key,"key_options":"no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding","passwordless_sudo":True}
  ]
}
with open(sys.argv[1],'w') as f: json.dump(vars,f)
os.chmod(sys.argv[1],0o600)
os.chown(sys.argv[1],0,0)
PY

info "Applying host hardening (no Docker or application stacks)"
ansible-playbook -i 'localhost,' -c local "$repo_dir/ansible/playbooks/harden-vps.yml" --extra-vars "@$vars_file"

cat <<DONE

Host hardening finished.
The reusable, root-only JSON settings are stored in $config_file.
The installer enabled host security controls, including firewalld and CrowdSec,
and automatic security updates. It did not install Docker or deploy application stacks.
DONE
