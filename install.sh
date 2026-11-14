#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly REPOSITORY_URL_DEFAULT="https://github.com/JOKU-Homelab/vps.git"
readonly DEFAULT_REF="main"
readonly INSTALL_ROOT="/opt/vps"
readonly BOOTSTRAP_DIR="/etc/vps-bootstrap"
readonly DEFAULT_INFISICAL_SECRET_PATHS="/bootstrap,/smtp,/backup,/pangolin,/pangolin-site,/authentik,/backrest,/beszel,/databasement,/renovate,/composeflux"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root, for example: curl -fsSL https://raw.githubusercontent.com/JOKU-Homelab/vps/main/install.sh | sudo bash"
[[ -r /etc/os-release ]] || die "Cannot identify this operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == almalinux || "${ID_LIKE:-}" == *rhel* ]] || die "This installer currently supports AlmaLinux/RHEL-family hosts only."

restore_override="${VPS_RESTORE_SNAPSHOT:-}"
repo_dir="$INSTALL_ROOT/repo"
while (($#)); do
  case "$1" in
    --restore) (($# >= 2)) || die "--restore needs a snapshot ID or latest"; restore_override="$2"; shift 2 ;;
    -h|--help)
      cat <<'USAGE'
Usage: install.sh [--restore SNAPSHOT]

Run as root on AlmaLinux/RHEL. Missing settings are prompted for and saved to
the Infisical project. Infisical endpoint and machine identity values are saved
immediately to a root-only local file. Use --restore to restore a snapshot.
USAGE
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

info "Installing Git, Python, Ansible, OpenSSL, and Infisical CLI"
dnf install -y git python3 python3-pip ansible-core openssl curl
if ! command -v infisical >/dev/null 2>&1; then
  curl -1sLf 'https://artifacts-cli.infisical.com/setup.rpm.sh' | bash
  dnf install -y infisical
fi

install -d -o root -g root -m 0700 "$BOOTSTRAP_DIR" /etc/vps
cloud_config="$BOOTSTRAP_DIR/infisical.env"
save_bootstrap_value() {
  local key="$1" value="$2"
  BOOTSTRAP_KEY="$key" BOOTSTRAP_VALUE="$value" python3 - "$cloud_config" <<'PY'
import os, pathlib, shlex, tempfile, sys
p=pathlib.Path(sys.argv[1])
lines=p.read_text().splitlines() if p.exists() else []
key=os.environ['BOOTSTRAP_KEY']; value=shlex.quote(os.environ['BOOTSTRAP_VALUE'])
updated=[]; found=False
for line in lines:
    if line.startswith(key+'='):
        updated.append(f'{key}={value}'); found=True
    else:
        updated.append(line)
if not found: updated.append(f'{key}={value}')
p.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
fd,tmp=tempfile.mkstemp(prefix='.infisical.env.', dir=p.parent)
try:
    with os.fdopen(fd,'w') as out: out.write('\n'.join(updated)+'\n')
    os.chmod(tmp,0o600); os.chown(tmp,0,0); os.replace(tmp,p)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
}

prompt_bootstrap_value() {
  local key="$1" label="$2" default_value="${3:-}" secret="${4:-false}" value
  value="${!key:-}"
  if [[ -z "$value" ]]; then
    if [[ "$secret" == true ]]; then
      IFS= read -r -s -p "$label: " value </dev/tty || die "Could not read $label."
      printf '\n' >/dev/tty
    else
      IFS= read -r -p "$label${default_value:+ [$default_value]}: " value </dev/tty || die "Could not read $label."
    fi
    value="${value:-$default_value}"
    [[ -n "$value" ]] || die "$label is required."
    printf -v "$key" '%s' "$value"
    save_bootstrap_value "$key" "$value"
  fi
}

if [[ -f "$cloud_config" ]] && grep -qx 'INFISICAL_CONNECTION_CONFIG=1' "$cloud_config"; then
  chmod 0600 "$cloud_config"; chown root:root "$cloud_config"
  # shellcheck disable=SC1090
  source "$cloud_config"
else
  # Replace legacy self-hosted bootstrap files, which contained service secrets.
  rm -f "$cloud_config"
  install -o root -g root -m 0600 /dev/null "$cloud_config"
  printf 'INFISICAL_CONNECTION_CONFIG=1\n' >"$cloud_config"
fi
prompt_bootstrap_value INFISICAL_DOMAIN "Infisical URL (Cloud default https://eu.infisical.com)" "https://eu.infisical.com"
prompt_bootstrap_value INFISICAL_PROJECT_ID "Infisical project ID"
prompt_bootstrap_value INFISICAL_ENVIRONMENT "Infisical environment" "prod"
prompt_bootstrap_value INFISICAL_CLIENT_ID "Universal Auth client ID"
prompt_bootstrap_value INFISICAL_CLIENT_SECRET "Universal Auth client secret" "" true
INFISICAL_SECRET_PATHS="${INFISICAL_SECRET_PATHS:-$DEFAULT_INFISICAL_SECRET_PATHS}"
save_bootstrap_value INFISICAL_SECRET_PATHS "$INFISICAL_SECRET_PATHS"
[[ "$INFISICAL_DOMAIN" == https://* ]] || die "Infisical URL must use HTTPS."
[[ -n "${INFISICAL_DOMAIN:-}" && -n "${INFISICAL_PROJECT_ID:-}" && -n "${INFISICAL_CLIENT_ID:-}" && -n "${INFISICAL_CLIENT_SECRET:-}" ]] || die "Incomplete $cloud_config."
export INFISICAL_DOMAIN INFISICAL_PROJECT_ID INFISICAL_ENVIRONMENT INFISICAL_SECRET_PATHS INFISICAL_CLIENT_ID INFISICAL_CLIENT_SECRET
refresh_infisical_token() {
  INFISICAL_TOKEN="$(infisical login --method=universal-auth --client-id="$INFISICAL_CLIENT_ID" --client-secret="$INFISICAL_CLIENT_SECRET" --silent --plain)" || die "Infisical Universal Auth login failed."
  [[ -n "$INFISICAL_TOKEN" ]] || die "Infisical did not return an access token."
  export INFISICAL_TOKEN
}
refresh_infisical_token
repository_url="$REPOSITORY_URL_DEFAULT"
ref="$DEFAULT_REF"
[[ -z "$restore_override" || "$restore_override" =~ ^(latest|[A-Fa-f0-9]{4,64})$ ]] || die "Snapshot must be 'latest' or a hexadecimal Restic snapshot ID."

info "Fetching repository ref $ref"
install -d -o root -g root -m 0755 "$INSTALL_ROOT"
if [[ -d "$repo_dir/.git" ]]; then
  git -C "$repo_dir" fetch --depth 1 origin "$ref"
  git -C "$repo_dir" checkout --force FETCH_HEAD
else
  git clone --depth 1 --branch "$ref" "$repository_url" "$repo_dir" || git clone --depth 1 "$repository_url" "$repo_dir"
  [[ "$ref" == "$DEFAULT_REF" ]] || git -C "$repo_dir" checkout --detach "$ref"
fi

info "Installing Ansible collections and Infisical secret support"
export ANSIBLE_CONFIG="$repo_dir/ansible/ansible.cfg"
ansible-galaxy collection install -r "$repo_dir/ansible/requirements.yml"
python3 -m pip install --user infisicalsdk

if ! grep -qx 'INFISICAL_BOOTSTRAP_SEEDED=1' "$cloud_config"; then
  needs_initial_setup=true
  refresh_infisical_token
  seed_file="$(mktemp /run/infisical-bootstrap.XXXXXX.json)"
  chmod 0600 "$seed_file"
  trap 'rm -f "${seed_file:-}"' EXIT
  export SEED_SERVER_SECRET="$(openssl rand -base64 48 | tr -d '\n')"
  export SEED_RESTIC_PASSWORD="$(openssl rand -hex 32)"
  export SEED_PG_PASS="$(openssl rand -hex 32)"
  export SEED_AUTHENTIK_SECRET_KEY="$(openssl rand -hex 48)"
  export SEED_APP_KEY="base64:$(openssl rand -base64 32 | tr -d '\n')"
  export SEED_REPOSITORY_URL="$repository_url" SEED_REPOSITORY_REF="$ref"
  SEED_MANIFEST="$seed_file" python3 - <<'PY'
import json, os
secret_folders = ["bootstrap", "smtp", "backup", "pangolin", "pangolin-site", "authentik", "backrest", "beszel", "databasement", "renovate", "composeflux"]
specs = {
 "bootstrap": [("VPS_BASE_DOMAIN","CHANGE_ME","Public base domain used to build service hostnames."),("VPS_ADMIN_EMAIL","CHANGE_ME","Email address used for TLS certificate registration."),("VPS_ADMIN_USER","admin","Linux administrator account created by Ansible."),("VPS_ADMIN_SSH_PUBLIC_KEY","CHANGE_ME","SSH public key authorized for the administrator account."),("TZ","Europe/Zurich","Timezone used by scheduled jobs and services.")],
 "smtp": [("SMTP_ENABLED","no","Enables outbound email delivery when set to yes."),("SMTP_HOST","CHANGE_ME","SMTP server hostname."),("SMTP_PORT","465","SMTP server port; Migadu implicit TLS uses 465."),("SMTP_USERNAME","CHANGE_ME","Username used to authenticate to the SMTP server."),("SMTP_PASSWORD","CHANGE_ME","Password used to authenticate to the SMTP server."),("SMTP_FROM_ADDRESS","CHANGE_ME","Sender address used for service email."),("SMTP_SECURE","true","Enables implicit TLS for SMTP connections.")],
 "backup": [("RESTIC_REPOSITORY","CHANGE_ME","Remote Restic repository location for encrypted backups."),("B2_ACCOUNT_ID","CHANGE_ME","Backblaze B2 account identifier for backup storage."),("B2_ACCOUNT_KEY","CHANGE_ME","Backblaze B2 application key for backup storage."),("RESTIC_PASSWORD",os.environ["SEED_RESTIC_PASSWORD"],"Encryption password required to read and restore Restic snapshots.")],
 "pangolin": [("SERVER_SECRET",os.environ["SEED_SERVER_SECRET"],"Secret key used by the Pangolin server to protect session and application data.")],
 "pangolin-site": [("PANGOLIN_ENDPOINT","CHANGE_ME","Public URL of the Pangolin server used by the site connector."),("SITE_ID","CHANGE_ME","Pangolin site identifier for this VPS."),("SITE_SECRET","CHANGE_ME","Authentication secret for this Pangolin site.")],
 "authentik": [("PG_USER","authentik","PostgreSQL role used by Authentik."),("PG_DB","authentik","PostgreSQL database used by Authentik."),("PG_PASS",os.environ["SEED_PG_PASS"],"PostgreSQL password used by Authentik."),("AUTHENTIK_SECRET_KEY",os.environ["SEED_AUTHENTIK_SECRET_KEY"],"Application signing and encryption key used by Authentik."),("AUTHENTIK_URL","CHANGE_ME","Public URL configured as Authentik's base URL."),("AUTHENTIK_DOMAIN","CHANGE_ME","Public hostname for the Authentik resource.")],
 "backrest": [("BACKREST_DOMAIN","CHANGE_ME","Public hostname for the Backrest backup interface.")],
 "beszel": [("BESZEL_URL","CHANGE_ME","Public URL configured for the Beszel Hub."),("BESZEL_DOMAIN","CHANGE_ME","Public hostname for the Beszel resource.")],
 "databasement": [("DATABASEMENT_URL","CHANGE_ME","Public URL configured for Databasement."),("DATABASEMENT_DOMAIN","CHANGE_ME","Public hostname for the Databasement resource."),("APP_KEY",os.environ["SEED_APP_KEY"],"Application encryption key used by Databasement."),("OAUTH_OIDC_ENABLED","false","Enables OpenID Connect login for Databasement when configured."),("OAUTH_OIDC_CLIENT_ID","CHANGE_ME","Authentik OAuth client ID used by Databasement."),("OAUTH_OIDC_CLIENT_SECRET","CHANGE_ME","Authentik OAuth client secret used by Databasement."),("OAUTH_OIDC_BASE_URL","CHANGE_ME","Authentik OpenID Connect issuer URL used by Databasement."),("OAUTH_OIDC_LABEL","Authentik","Display label for the Databasement OpenID Connect login option."),("OAUTH_AUTO_CREATE_USERS","false","Allows first-time OpenID Connect login to create Databasement users."),("OAUTH_AUTO_LINK_BY_EMAIL","true","Links OpenID Connect users to existing accounts with the same email.")],
 "renovate": [("RENOVATE_REPOSITORIES","CHANGE_ME","GitHub repository Renovate is allowed to update."),("RENOVATE_TOKEN","CHANGE_ME","GitHub token used by Renovate to create update pull requests.")],
 "composeflux": [("COMPOSEFLUX_CLIENT_ID","CHANGE_ME","Universal Auth client ID for ComposeFlux read-only access."),("COMPOSEFLUX_CLIENT_SECRET","CHANGE_ME","Universal Auth client secret for ComposeFlux read-only access."),("COMPOSEFLUX_GIT_REPO_URL",os.environ["SEED_REPOSITORY_URL"],"Git repository URL ComposeFlux reconciles."),("COMPOSEFLUX_GIT_BRANCH",os.environ["SEED_REPOSITORY_REF"],"Git branch or ref ComposeFlux reconciles.")]
}
secrets=[]
for folder, entries in specs.items():
    for name, value, comment in entries:
        secrets.append({"path":"/"+folder,"name":name,"value":value,"comment":comment})
with open(os.environ["SEED_MANIFEST"], "w") as f:
    json.dump({"secret_folders":secret_folders,"secrets":secrets}, f)
PY
  printf 'Required secrets and first-run configuration are being initialized in Infisical.\n'
  ansible-playbook -i 'localhost,' -c local "$repo_dir/ansible/playbooks/seed-infisical.yml" --extra-vars "seed_manifest=$seed_file"
  rm -f "$seed_file"
  trap - EXIT
  printf 'INFISICAL_BOOTSTRAP_SEEDED=1\n' >>"$cloud_config"
else
  needs_initial_setup=false
fi

cat <<'PROMPT'

Infisical now contains generated bootstrap secrets and configuration placeholders.
Open the project in Infisical and fill the first-run values still set to CHANGE_ME:
  /bootstrap: VPS_BASE_DOMAIN, VPS_ADMIN_EMAIL, VPS_ADMIN_SSH_PUBLIC_KEY
  /smtp: SMTP_HOST, SMTP_USERNAME, SMTP_PASSWORD, SMTP_FROM_ADDRESS (or keep SMTP_ENABLED=no)
  /backup: RESTIC_REPOSITORY, B2_ACCOUNT_ID, B2_ACCOUNT_KEY
  /authentik: AUTHENTIK_URL, AUTHENTIK_DOMAIN
  /backrest: BACKREST_DOMAIN; /beszel: BESZEL_URL, BESZEL_DOMAIN
  /databasement: DATABASEMENT_URL, DATABASEMENT_DOMAIN
  /renovate: RENOVATE_REPOSITORIES, RENOVATE_TOKEN
Every installer-created secret has a comment describing its purpose.
Change VPS_ADMIN_USER if you do not want the default "admin". After Pangolin's
first-run setup, create a read-only Infisical machine identity for ComposeFlux
and set COMPOSEFLUX_CLIENT_ID and COMPOSEFLUX_CLIENT_SECRET in this project.

The Universal Auth identity needs write access only when this project is first
seeded. After the values exist, reduce it to read-only access. ComposeFlux gets
its own read-only identity below.
PROMPT
if [[ "$needs_initial_setup" == true ]]; then
  [[ -r /dev/tty ]] || die "Complete the Infisical project values, then rerun this installer."
  IFS= read -r -p "Type CONTINUE after filling the Infisical values: " continue_setup </dev/tty || die "Could not read confirmation."
  [[ "$continue_setup" == CONTINUE ]] || die "Setup paused; rerun install.sh after updating Infisical."
fi

validate_secrets() {
  refresh_infisical_token
  "$repo_dir/ansible/files/vps-infisical-run" bash -euc '
      for key in VPS_BASE_DOMAIN VPS_ADMIN_EMAIL VPS_ADMIN_SSH_PUBLIC_KEY SERVER_SECRET RESTIC_REPOSITORY B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_PASSWORD AUTHENTIK_SECRET_KEY AUTHENTIK_URL AUTHENTIK_DOMAIN BACKREST_DOMAIN BESZEL_URL BESZEL_DOMAIN DATABASEMENT_URL DATABASEMENT_DOMAIN APP_KEY RENOVATE_REPOSITORIES RENOVATE_TOKEN COMPOSEFLUX_GIT_REPO_URL; do
        value="${!key:-}"
        [[ -n "$value" && "$value" != CHANGE_ME ]] || { echo "Infisical secret $key is empty or still CHANGE_ME" >&2; exit 1; }
      done
      [[ "${VPS_BASE_DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "VPS_BASE_DOMAIN must be a hostname without a URL scheme" >&2; exit 1; }
      [[ "${VPS_ADMIN_EMAIL}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo "VPS_ADMIN_EMAIL must be a valid email address" >&2; exit 1; }
      [[ "${VPS_ADMIN_USER:-admin}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || { echo "VPS_ADMIN_USER is not a valid Linux username" >&2; exit 1; }
      [[ "${VPS_ADMIN_SSH_PUBLIC_KEY}" == ssh-ed25519\ * || "${VPS_ADMIN_SSH_PUBLIC_KEY}" == ecdsa-sha2-nistp*\ * || "${VPS_ADMIN_SSH_PUBLIC_KEY}" == ssh-rsa\ * ]] || { echo "VPS_ADMIN_SSH_PUBLIC_KEY must be an SSH public key" >&2; exit 1; }
      [[ "${SMTP_ENABLED:-no}" == yes || "${SMTP_ENABLED:-no}" == no ]] || { echo "SMTP_ENABLED must be yes or no" >&2; exit 1; }
      [[ "${SMTP_SECURE:-true}" == true || "${SMTP_SECURE:-true}" == false ]] || { echo "SMTP_SECURE must be true or false" >&2; exit 1; }
      [[ "${SMTP_ENABLED:-no}" == no || ( -n "${SMTP_HOST:-}" && "${SMTP_HOST:-}" != CHANGE_ME && -n "${SMTP_USERNAME:-}" && "${SMTP_USERNAME:-}" != CHANGE_ME && -n "${SMTP_PASSWORD:-}" && "${SMTP_PASSWORD:-}" != CHANGE_ME && -n "${SMTP_FROM_ADDRESS:-}" && "${SMTP_FROM_ADDRESS:-}" != CHANGE_ME ) ]] || { echo "Complete SMTP secrets or set SMTP_ENABLED=no" >&2; exit 1; }
    '
}
until validate_secrets; do
  [[ -r /dev/tty ]] || die "Fix the listed values in Infisical, then rerun install.sh."
  IFS= read -r -p "Fix the listed Infisical values, then press Enter to retry: " _ </dev/tty || die "Could not read confirmation."
done

# Remove legacy local copies now that Infisical has passed the bootstrap checks.
rm -f /etc/vps/install.conf /etc/vps/backup.env /etc/vps/restic-password \
  "$BOOTSTRAP_DIR/pangolin.env" "$BOOTSTRAP_DIR/pangolin-seed.env" \
  "$BOOTSTRAP_DIR/site.yml"
if [[ -f "$BOOTSTRAP_DIR/composeflux.env" ]] && ! grep -qx 'INFISICAL_READONLY_CONFIG=1' "$BOOTSTRAP_DIR/composeflux.env"; then
  rm -f "$BOOTSTRAP_DIR/composeflux.env"
fi

info "Initializing the host"
refresh_infisical_token
ansible_extra_vars=()
if [[ -n "$restore_override" ]]; then ansible_extra_vars+=(--extra-vars "vps_restore_snapshot=$restore_override"); fi
"$repo_dir/ansible/files/vps-infisical-run" ansible-playbook -i 'localhost,' -c local "$repo_dir/ansible/playbooks/initialize-vps.yml" "${ansible_extra_vars[@]}"
if [[ -z "$restore_override" ]]; then "$repo_dir/ansible/files/vps-infisical-run" /usr/local/sbin/vps-backup init; fi

if [[ -z "$restore_override" && ! -f "$BOOTSTRAP_DIR/composeflux.env" ]]; then
  cat <<'PANGOLIN_SETUP'

Pangolin is running. Open its public URL and finish the first administrator setup.
Create the Pangolin site for this host. In Infisical, then set:
  PANGOLIN_ENDPOINT=https://pangolin.<your VPS base domain>
  SITE_ID=<the Pangolin site ID>
  SITE_SECRET=<the Pangolin site secret>
Confirm the remaining application values are complete before continuing.
Create a read-only Infisical machine identity for ComposeFlux and set its client
ID and secret as COMPOSEFLUX_CLIENT_ID and COMPOSEFLUX_CLIENT_SECRET.
PANGOLIN_SETUP
  [[ -r /dev/tty ]] || die "Complete Pangolin and ComposeFlux setup, then rerun install.sh."
  IFS= read -r -p "Type CONTINUE when the Pangolin and application secrets are ready: " continue_gitops </dev/tty || die "Could not read confirmation."
  [[ "$continue_gitops" == CONTINUE ]] || die "Setup paused; rerun install.sh after updating Infisical."
fi

validate_managed_secrets() {
  refresh_infisical_token
  "$repo_dir/ansible/files/vps-infisical-run" bash -euc '
      for key in PANGOLIN_ENDPOINT SITE_ID SITE_SECRET COMPOSEFLUX_CLIENT_ID COMPOSEFLUX_CLIENT_SECRET; do
        value="${!key:-}"
        [[ -n "$value" && "$value" != CHANGE_ME ]] || { echo "Infisical secret $key is empty or still CHANGE_ME" >&2; exit 1; }
      done
    '
}
until validate_managed_secrets; do
  [[ -r /dev/tty ]] || die "Fix the listed values in Infisical, then rerun install.sh."
  IFS= read -r -p "Fix the listed Infisical values, then press Enter to retry: " _ </dev/tty || die "Could not read confirmation."
done

refresh_infisical_token
"$repo_dir/ansible/files/vps-infisical-run" python3 - <<'PY'
import os, pathlib, shlex
p=pathlib.Path('/etc/vps-bootstrap/composeflux.env')
values={
    'INFISICAL_READONLY_CONFIG':'1',
    'INFISICAL_DOMAIN':os.environ['INFISICAL_DOMAIN'],
    'INFISICAL_PROJECT_ID':os.environ['INFISICAL_PROJECT_ID'],
    'INFISICAL_ENVIRONMENT':os.environ['INFISICAL_ENVIRONMENT'],
    'INFISICAL_SECRET_PATH':os.environ['INFISICAL_SECRET_PATHS'],
    'INFISICAL_CLIENT_ID':os.environ['COMPOSEFLUX_CLIENT_ID'],
    'INFISICAL_CLIENT_SECRET':os.environ['COMPOSEFLUX_CLIENT_SECRET'],
}
p.write_text(''.join(f'{k}={shlex.quote(v)}\n' for k,v in values.items()))
p.chmod(0o600); os.chown(p,0,0)
PY

refresh_infisical_token
"$repo_dir/ansible/files/vps-infisical-run" ansible-playbook -i 'localhost,' -c local "$repo_dir/ansible/playbooks/enable-gitops.yml"

cat <<DONE

Initialization finished. Configuration and service secrets are stored in Infisical.
The local Infisical connection credential is in $cloud_config (root-only mode 0600).
Keep a protected copy of that credential or enter it again when restoring a new VPS.
DONE
