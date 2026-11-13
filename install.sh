#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly REPOSITORY_URL_DEFAULT="https://github.com/JOKU-Homelab/vps.git"
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

ref_override="${VPS_REF:-}"
restore_override="${VPS_RESTORE_SNAPSHOT:-}"
config_file="$CONFIG_PATH"
config_mode=false
repo_dir="$INSTALL_ROOT/repo"
while (($#)); do
  case "$1" in
    --ref) (($# >= 2)) || die "--ref needs a tag or branch"; ref_override="$2"; shift 2 ;;
    --restore) (($# >= 2)) || die "--restore needs a snapshot ID or latest"; restore_override="$2"; shift 2 ;;
    --config) (($# >= 2)) || die "--config needs a path to install.conf"; config_file="$2"; config_mode=true; shift 2 ;;
    -h|--help)
      cat <<'USAGE'
Usage: install.sh [--config FILE] [--ref TAG_OR_BRANCH] [--restore SNAPSHOT]

Run as root on AlmaLinux/RHEL. Missing settings are prompted for and saved to
install.conf immediately. With --config, the installer restores the latest
snapshot by default; --restore selects another snapshot.

The config file contains recovery secrets. Protect it as you would a password
vault export. Without --config, /etc/vps/install.conf is reused but no restore
is run unless --restore is given.
USAGE
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

info "Installing Git, Python, Ansible, and OpenSSL"
dnf install -y git python3 ansible-core openssl

if [[ -f "$config_file" ]]; then
  [[ -r "$config_file" ]] || die "Cannot read config file: $config_file"
  chmod 0600 "$config_file"
  chown root:root "$config_file"
  eval "$(python3 - "$config_file" <<'PY'
import json, pathlib, shlex, sys
p = pathlib.Path(sys.argv[1])
try:
    c = json.loads(p.read_text())
except Exception as e:
    raise SystemExit(f"invalid install.conf: {e}")
if c.get("schema_version", 1) != 1:
    raise SystemExit("unsupported install.conf schema_version")
keys = ("repository_url", "ref", "admin_user", "admin_ssh_public_key", "base_domain", "admin_email", "restic_repository", "b2_account_id", "b2_account_key", "restic_password")
values = {key: c.get(key) for key in keys}
bootstrap = c.get("bootstrap", {})
if isinstance(bootstrap, dict):
    old_backup = bootstrap.get("backup_env", "")
    if isinstance(old_backup, str):
        names = {"RESTIC_REPOSITORY":"restic_repository", "B2_ACCOUNT_ID":"b2_account_id", "B2_ACCOUNT_KEY":"b2_account_key"}
        for line in old_backup.splitlines():
            if "=" in line:
                name, value = line.split("=", 1)
                if name in names and not values[names[name]]: values[names[name]] = value
    if not values["restic_password"]: values["restic_password"] = bootstrap.get("restic_password")
for key, value in values.items():
    if value in (None, ""): continue
    if not isinstance(value, str): raise SystemExit(f"install.conf field {key} must be a string")
    print(f"{key}={shlex.quote(value)}")
PY
  )" || die "Could not load install.conf"
fi

repository_url="${repository_url:-$REPOSITORY_URL_DEFAULT}"
ref="${ref_override:-${ref:-$DEFAULT_REF}}"
admin_user="${admin_user:-${VPS_ADMIN_USER:-}}"
admin_ssh_public_key="${admin_ssh_public_key:-${VPS_ADMIN_SSH_KEY:-}}"
base_domain="${base_domain:-${VPS_BASE_DOMAIN:-}}"
admin_email="${admin_email:-${VPS_ADMIN_EMAIL:-}}"
restic_repository="${restic_repository:-${RESTIC_REPOSITORY:-}}"
b2_account_id="${b2_account_id:-${B2_ACCOUNT_ID:-}}"
b2_account_key="${b2_account_key:-${B2_ACCOUNT_KEY:-}}"
restic_password="${restic_password:-${RESTIC_PASSWORD:-}}"

persist_config() {
  local kind="$1" key="$2" value="$3"
  INSTALL_CONFIG_FILE="$config_file" INSTALL_KEY="$key" INSTALL_KIND="$kind" INSTALL_VALUE="$value" python3 - "$CONFIG_PATH" <<'PY'
import json, os, pathlib, tempfile, sys
targets=[]
for name in (os.environ["INSTALL_CONFIG_FILE"], sys.argv[1]):
    p=pathlib.Path(name).expanduser()
    if p not in targets: targets.append(p)
for p in targets:
    if p.exists():
        try: data=json.loads(p.read_text())
        except Exception as e: raise SystemExit(f"invalid install.conf {p}: {e}")
    else: data={"schema_version":1}
    if data.get("schema_version",1) != 1: raise SystemExit("unsupported install.conf schema_version")
    data["schema_version"]=1
    if os.environ["INSTALL_KIND"] == "bootstrap":
        data.setdefault("bootstrap", {})[os.environ["INSTALL_KEY"]]=os.environ["INSTALL_VALUE"]
    else:
        data[os.environ["INSTALL_KEY"]]=os.environ["INSTALL_VALUE"]
    p.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix=".install.conf.", dir=p.parent)
    try:
        with os.fdopen(fd,"w") as out: json.dump(data,out,indent=2); out.write("\n")
        os.chmod(tmp,0o600); os.chown(tmp,0,0); os.replace(tmp,p)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
PY
}

collect_value() {
  local var_name="$1" field="$2" label="$3" default_value="${4:-}" secret="${5:-false}" value
  value="${!var_name:-}"
  if [[ -z "$value" ]]; then
    if [[ -n "$default_value" ]]; then
      value="$default_value"
    else
      [[ -r /dev/tty ]] || die "Missing $label in $config_file and no interactive terminal is available."
      if [[ "$secret" == true ]]; then
        IFS= read -r -s -p "$label: " value </dev/tty || die "Could not read $label."
        printf '\n' >/dev/tty
      else
        IFS= read -r -p "$label: " value </dev/tty || die "Could not read $label."
      fi
    fi
  fi
  [[ -n "$value" ]] || die "$label is required."
  case "$field" in
    repository_url) [[ "$value" == https://* ]] || die "Repository URL must use HTTPS." ;;
    ref) [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "Invalid Git ref." ;;
    admin_user) [[ "$value" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Invalid Linux username." ;;
    admin_ssh_public_key) [[ "$value" == ssh-ed25519\ * || "$value" == ecdsa-sha2-nistp*\ * || "$value" == ssh-rsa\ * ]] || die "The SSH key does not look like a supported public key." ;;
    base_domain) [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || die "Enter a domain name without a scheme or path." ;;
    admin_email) [[ "$value" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "Enter a valid email address." ;;
    restic_repository) [[ "$value" =~ ^[A-Za-z0-9:/._@+-]+$ ]] || die "Repository URL contains unsupported characters." ;;
    b2_account_id|b2_account_key) [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]] || die "$label contains unsupported characters." ;;
  esac
  printf -v "$var_name" '%s' "$value"
  persist_config setting "$field" "$value"
}

collect_value repository_url repository_url "Repository URL" "$REPOSITORY_URL_DEFAULT"
collect_value ref ref "Git ref" "$DEFAULT_REF"
collect_value admin_user admin_user "Administrator login name" "admin"
collect_value admin_ssh_public_key admin_ssh_public_key "Administrator SSH public key (single line)"
collect_value base_domain base_domain "Base domain for public services"
collect_value admin_email admin_email "Administrator/ACME email address"
collect_value restic_repository restic_repository "Restic repository (for example b2:bucket-name:/vps)"
collect_value b2_account_id b2_account_id "Backblaze B2 account ID"
collect_value b2_account_key b2_account_key "Backblaze B2 application key" "" true
collect_value restic_password restic_password "Restic repository password" "" true

if [[ -n "$restore_override" ]]; then
  restore_snapshot="$restore_override"
elif [[ "$config_mode" == true ]]; then
  restore_snapshot="latest"
else
  restore_snapshot=""
fi
[[ -z "$restore_snapshot" || "$restore_snapshot" =~ ^(latest|[A-Fa-f0-9]{4,64})$ ]] || die "Snapshot must be 'latest' or a hexadecimal Restic snapshot ID."

export repository_url ref admin_user admin_ssh_public_key base_domain admin_email
export restic_repository b2_account_id b2_account_key restic_password
install -d -o root -g root -m 0700 "$BOOTSTRAP_DIR" /etc/vps

if [[ "$config_mode" == true && -f "$config_file" ]]; then
  python3 - "$config_file" <<'PY'
import json, os, pathlib, sys
c=json.loads(pathlib.Path(sys.argv[1]).read_text())
for key in ("infisical_env","pangolin_env","composeflux_env"):
    content=c.get("bootstrap",{}).get(key)
    if isinstance(content,str) and content:
        name=key[:-4]+".env"
        p=pathlib.Path("/etc/vps-bootstrap")/name
        p.write_text(content.rstrip("\n")+"\n"); p.chmod(0o600); os.chown(p,0,0)
PY
fi

infisical_backend_running=false
if command -v docker >/dev/null 2>&1 && [[ "$(docker inspect -f '{{.State.Running}}' infisical-backend 2>/dev/null || true)" == true ]]; then
  infisical_backend_running=true
fi
INFISICAL_BOOTSTRAP_PORT="$(python3 - "$BOOTSTRAP_DIR/infisical.env" "$infisical_backend_running" <<'PY'
import pathlib, socket, sys
path=pathlib.Path(sys.argv[1])
running=sys.argv[2] == "true"
existing=""
if path.exists():
    for line in path.read_text().splitlines():
        if line.startswith("INFISICAL_BOOTSTRAP_PORT="):
            existing=line.split("=",1)[1].strip()
            break
if existing:
    if not existing.isdigit() or not 1024 <= int(existing) <= 65535:
        raise SystemExit("INFISICAL_BOOTSTRAP_PORT must be a TCP port from 1024 to 65535")
    if running:
        print(existing); raise SystemExit(0)
    candidates=[int(existing)]
else:
    candidates=[]
candidates += [p for p in range(18080,18101) if p not in candidates]
for port in candidates:
    sock=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
    try:
        sock.bind(("127.0.0.1",port))
        print(port)
        break
    except OSError:
        pass
    finally:
        sock.close()
else:
    raise SystemExit("No free Infisical bootstrap port found in 18080-18100; set INFISICAL_BOOTSTRAP_PORT manually")
PY
)" || die "Could not select a free loopback port for Infisical."
python3 - "$BOOTSTRAP_DIR/infisical.env" "$INFISICAL_BOOTSTRAP_PORT" <<'PY'
import os, pathlib, sys
p=pathlib.Path(sys.argv[1]); key="INFISICAL_BOOTSTRAP_PORT"; value=sys.argv[2]
lines=p.read_text().splitlines() if p.exists() else []
found=False; output=[]
for line in lines:
    if line.startswith(key+"="):
        output.append(f"{key}={value}"); found=True
    else: output.append(line)
if not found: output.append(f"{key}={value}")
p.write_text("\n".join(output)+"\n"); p.chmod(0o600); os.chown(p,0,0)
PY

python3 - <<'PY'
import base64, os, pathlib, secrets
boot=pathlib.Path('/etc/vps-bootstrap')
def write_env(path, values):
    path.write_text(''.join(f'{k}={v}\n' for k,v in values.items())); path.chmod(0o600); os.chown(path,0,0)
domain=os.environ['base_domain']; email=os.environ['admin_email']
if not (boot/'infisical.env').exists():
    enc=secrets.token_hex(16); auth=base64.b64encode(secrets.token_bytes(32)).decode(); pg=secrets.token_hex(32); redis=secrets.token_hex(32)
    write_env(boot/'infisical.env', {'ENCRYPTION_KEY':enc,'AUTH_SECRET':auth,'POSTGRES_USER':'infisical','POSTGRES_PASSWORD':pg,'POSTGRES_DB':'infisical','DB_CONNECTION_URI':f'postgresql://infisical:{pg}@db:5432/infisical','REDIS_PASSWORD':redis,'REDIS_URL':f'redis://:{redis}@redis:6379/0','SITE_URL':f'https://infisical.{domain}','INFISICAL_PUBLIC_DOMAIN':f'infisical.{domain}'})
if not (boot/'pangolin.env').exists():
    secret=base64.b64encode(secrets.token_bytes(48)).decode()
    write_env(boot/'pangolin.env', {'SERVER_SECRET':secret,'BASE_DOMAIN':domain,'PANGOLIN_DOMAIN':f'pangolin.{domain}','LETSENCRYPT_EMAIL':email,'INFISICAL_PUBLIC_DOMAIN':f'infisical.{domain}'})
if not (boot/'composeflux.env').exists():
    write_env(boot/'composeflux.env', {'GIT_REPO_URL':os.environ['repository_url'],'GIT_BRANCH':os.environ['ref'],'INFISICAL_SITE_URL':'http://infisical-api:8080','INFISICAL_ENVIRONMENT':'prod','INFISICAL_PROJECT_ID':'SET_AFTER_INFISICAL_SETUP','INFISICAL_CLIENT_ID':'SET_AFTER_INFISICAL_SETUP','INFISICAL_CLIENT_SECRET':'SET_AFTER_INFISICAL_SETUP','INFISICAL_SECRET_PATH':'/'})
PY

if [[ "$config_mode" == false ]]; then
  python3 - <<'PY'
import os, pathlib
p=pathlib.Path('/etc/vps-bootstrap/composeflux.env')
lines=p.read_text().splitlines()
updates={'GIT_REPO_URL':os.environ['repository_url'],'GIT_BRANCH':os.environ['ref']}
found=set(); result=[]
for line in lines:
    key=line.split('=',1)[0] if '=' in line else ''
    if key in updates:
        result.append(f'{key}={updates[key]}'); found.add(key)
    else: result.append(line)
for key,value in updates.items():
    if key not in found: result.append(f'{key}={value}')
p.write_text('\n'.join(result)+'\n'); p.chmod(0o600); os.chown(p,0,0)
PY
fi

for name in infisical pangolin composeflux; do
  persist_config bootstrap "${name}_env" "$(cat "$BOOTSTRAP_DIR/${name}.env")"
done

python3 - <<'PY'
import json, os, pathlib
site={'vps_base_domain':os.environ['base_domain'],'vps_admin_email':os.environ['admin_email'],'vps_users':[{'name':os.environ['admin_user'],'comment':'VPS administrator','shell':'/bin/bash','groups':['wheel','docker'],'public_key':os.environ['admin_ssh_public_key'],'passwordless_sudo':True},{'name':'ansible','comment':'Ansible service account','shell':'/bin/bash','groups':['wheel'],'public_key':os.environ['admin_ssh_public_key'],'key_options':'no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding','passwordless_sudo':True}]}
p=pathlib.Path('/etc/vps-bootstrap/site.yml'); p.write_text(json.dumps(site,indent=2)+'\n'); p.chmod(0o600); os.chown(p,0,0)
backup=pathlib.Path('/etc/vps/backup.env')
backup.write_text(f"RESTIC_REPOSITORY={os.environ['restic_repository']}\nB2_ACCOUNT_ID={os.environ['b2_account_id']}\nB2_ACCOUNT_KEY={os.environ['b2_account_key']}\n")
backup.chmod(0o600); os.chown(backup,0,0)
password=pathlib.Path('/etc/vps/restic-password'); password.write_text(os.environ['restic_password']+'\n'); password.chmod(0o600); os.chown(password,0,0)
PY

info "Fetching repository ref $ref"
install -d -o root -g root -m 0755 "$INSTALL_ROOT"
if [[ -d "$repo_dir/.git" ]]; then
  git -C "$repo_dir" fetch --depth 1 origin "$ref"
  git -C "$repo_dir" checkout --force FETCH_HEAD
else
  git clone --depth 1 --branch "$ref" "$repository_url" "$repo_dir" || git clone --depth 1 "$repository_url" "$repo_dir"
  [[ "$ref" == "$DEFAULT_REF" ]] || git -C "$repo_dir" checkout --detach "$ref"
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
Infisical bootstrap port: 127.0.0.1:$INFISICAL_BOOTSTRAP_PORT (forward this over SSH).
Keep a protected copy off-server. A replacement VPS can be initialized without
prompts using install.sh --config /path/to/install.conf.
DONE
