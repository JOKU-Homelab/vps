#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly REPOSITORY_URL_DEFAULT="https://github.com/JOKU-Homelab/vps.git"
readonly DEFAULT_REF="main"
readonly INSTALL_ROOT="/opt/vps"
readonly BOOTSTRAP_DIR="/etc/vps-bootstrap"

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
dnf install -y git python3 ansible-core openssl curl
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
prompt_bootstrap_value INFISICAL_DOMAIN "Infisical URL (Cloud default https://app.infisical.com)" "https://app.infisical.com"
prompt_bootstrap_value INFISICAL_PROJECT_ID "Infisical project ID"
prompt_bootstrap_value INFISICAL_ENVIRONMENT "Infisical environment" "prod"
prompt_bootstrap_value INFISICAL_SECRET_PATH "Infisical secret path" "/"
prompt_bootstrap_value INFISICAL_CLIENT_ID "Universal Auth client ID"
prompt_bootstrap_value INFISICAL_CLIENT_SECRET "Universal Auth client secret" "" true
[[ "$INFISICAL_DOMAIN" == https://* ]] || die "Infisical URL must use HTTPS."
[[ -n "${INFISICAL_DOMAIN:-}" && -n "${INFISICAL_PROJECT_ID:-}" && -n "${INFISICAL_CLIENT_ID:-}" && -n "${INFISICAL_CLIENT_SECRET:-}" ]] || die "Incomplete $cloud_config."
export INFISICAL_DOMAIN INFISICAL_PROJECT_ID INFISICAL_ENVIRONMENT INFISICAL_SECRET_PATH INFISICAL_CLIENT_ID INFISICAL_CLIENT_SECRET
refresh_infisical_token() {
  INFISICAL_TOKEN="$(infisical login --method=universal-auth --client-id="$INFISICAL_CLIENT_ID" --client-secret="$INFISICAL_CLIENT_SECRET" --silent --plain)" || die "Infisical Universal Auth login failed."
  [[ -n "$INFISICAL_TOKEN" ]] || die "Infisical did not return an access token."
  export INFISICAL_TOKEN
}
refresh_infisical_token
repository_url="$REPOSITORY_URL_DEFAULT"
ref="$DEFAULT_REF"
[[ -z "$restore_override" || "$restore_override" =~ ^(latest|[A-Fa-f0-9]{4,64})$ ]] || die "Snapshot must be 'latest' or a hexadecimal Restic snapshot ID."

if ! grep -qx 'INFISICAL_BOOTSTRAP_SEEDED=1' "$cloud_config"; then
  needs_initial_setup=false
  refresh_infisical_token
  if infisical run --token="$INFISICAL_TOKEN" --projectId="$INFISICAL_PROJECT_ID" \
    --env="$INFISICAL_ENVIRONMENT" --path="$INFISICAL_SECRET_PATH" -- bash -euc 'test -n "${SERVER_SECRET:-}"' >/dev/null 2>&1; then
    # Rebuilds and restores can use a read-only identity once the project was seeded.
    printf 'INFISICAL_BOOTSTRAP_SEEDED=1\n' >>"$cloud_config"
  else
  needs_initial_setup=true
  seed_file="$(mktemp /run/infisical-bootstrap.XXXXXX)"
  chmod 0600 "$seed_file"
  trap 'rm -f "${seed_file:-}"' EXIT
  printf 'SERVER_SECRET=%s\n' "$(openssl rand -base64 48 | tr -d '\n')" >"$seed_file"
  printf 'VPS_BASE_DOMAIN=CHANGE_ME\nVPS_ADMIN_EMAIL=CHANGE_ME\nVPS_ADMIN_USER=admin\nVPS_ADMIN_SSH_PUBLIC_KEY=CHANGE_ME\n' >>"$seed_file"
  printf 'SMTP_ENABLED=no\nSMTP_HOST=CHANGE_ME\nSMTP_PORT=465\nSMTP_USERNAME=CHANGE_ME\nSMTP_PASSWORD=CHANGE_ME\nSMTP_FROM_ADDRESS=CHANGE_ME\nSMTP_SECURE=true\n' >>"$seed_file"
  printf 'RESTIC_REPOSITORY=CHANGE_ME\nB2_ACCOUNT_ID=CHANGE_ME\nB2_ACCOUNT_KEY=CHANGE_ME\nRESTIC_PASSWORD=%s\n' "$(openssl rand -hex 32)" >>"$seed_file"
  printf 'PG_USER=authentik\nPG_DB=authentik\nPG_PASS=%s\nAUTHENTIK_SECRET_KEY=%s\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 48)" >>"$seed_file"
  printf 'AUTHENTIK_URL=CHANGE_ME\nAUTHENTIK_DOMAIN=CHANGE_ME\nBACKREST_DOMAIN=CHANGE_ME\nBESZEL_URL=CHANGE_ME\nBESZEL_DOMAIN=CHANGE_ME\n' >>"$seed_file"
  printf 'DATABASEMENT_URL=CHANGE_ME\nDATABASEMENT_DOMAIN=CHANGE_ME\nAPP_KEY=base64:%s\n' "$(openssl rand -base64 32 | tr -d '\n')" >>"$seed_file"
  printf 'PANGOLIN_ENDPOINT=CHANGE_ME\nSITE_ID=CHANGE_ME\nSITE_SECRET=CHANGE_ME\nRENOVATE_REPOSITORIES=CHANGE_ME\nRENOVATE_TOKEN=CHANGE_ME\nTZ=Europe/Zurich\n' >>"$seed_file"
  printf 'COMPOSEFLUX_CLIENT_ID=CHANGE_ME\nCOMPOSEFLUX_CLIENT_SECRET=CHANGE_ME\n' >>"$seed_file"
  printf 'COMPOSEFLUX_GIT_REPO_URL=%s\nCOMPOSEFLUX_GIT_BRANCH=%s\n' "$repository_url" "$ref" >>"$seed_file"
  printf 'Required secrets and first-run configuration are being initialized in Infisical.\n'
  infisical secrets set --file="$seed_file" --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENVIRONMENT" --path="$INFISICAL_SECRET_PATH"
  rm -f "$seed_file"
  trap - EXIT
  printf 'INFISICAL_BOOTSTRAP_SEEDED=1\n' >>"$cloud_config"
  fi
else
  needs_initial_setup=false
fi

cat <<'PROMPT'

Infisical now contains generated bootstrap secrets and configuration placeholders.
Open the project in Infisical and fill the first-run values still set to CHANGE_ME:
  VPS_BASE_DOMAIN, VPS_ADMIN_EMAIL, VPS_ADMIN_SSH_PUBLIC_KEY
  SMTP_HOST, SMTP_USERNAME, SMTP_PASSWORD, SMTP_FROM_ADDRESS (or leave SMTP_ENABLED=no)
  RESTIC_REPOSITORY, B2_ACCOUNT_ID, B2_ACCOUNT_KEY
  AUTHENTIK_URL, AUTHENTIK_DOMAIN, BACKREST_DOMAIN, BESZEL_URL, BESZEL_DOMAIN
  DATABASEMENT_URL, DATABASEMENT_DOMAIN, RENOVATE_REPOSITORIES, RENOVATE_TOKEN
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
  infisical run --token="$INFISICAL_TOKEN" --projectId="$INFISICAL_PROJECT_ID" \
    --env="$INFISICAL_ENVIRONMENT" --path="$INFISICAL_SECRET_PATH" -- bash -euc '
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
refresh_infisical_token
cloud_run=(infisical run --token="$INFISICAL_TOKEN" --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENVIRONMENT" --path="$INFISICAL_SECRET_PATH" --)
ansible_extra_vars=()
if [[ -n "$restore_override" ]]; then ansible_extra_vars+=(--extra-vars "vps_restore_snapshot=$restore_override"); fi
"${cloud_run[@]}" ansible-playbook -i 'localhost,' -c local "$repo_dir/ansible/playbooks/initialize-vps.yml" "${ansible_extra_vars[@]}"
if [[ -z "$restore_override" ]]; then "${cloud_run[@]}" /usr/local/sbin/vps-backup init; fi

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
  infisical run --token="$INFISICAL_TOKEN" --projectId="$INFISICAL_PROJECT_ID" \
    --env="$INFISICAL_ENVIRONMENT" --path="$INFISICAL_SECRET_PATH" -- bash -euc '
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
cloud_run=(infisical run --token="$INFISICAL_TOKEN" --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENVIRONMENT" --path="$INFISICAL_SECRET_PATH" --)
"${cloud_run[@]}" python3 - <<'PY'
import os, pathlib, shlex
p=pathlib.Path('/etc/vps-bootstrap/composeflux.env')
values={
    'INFISICAL_READONLY_CONFIG':'1',
    'INFISICAL_DOMAIN':os.environ['INFISICAL_DOMAIN'],
    'INFISICAL_PROJECT_ID':os.environ['INFISICAL_PROJECT_ID'],
    'INFISICAL_ENVIRONMENT':os.environ['INFISICAL_ENVIRONMENT'],
    'INFISICAL_SECRET_PATH':os.environ['INFISICAL_SECRET_PATH'],
    'INFISICAL_CLIENT_ID':os.environ['COMPOSEFLUX_CLIENT_ID'],
    'INFISICAL_CLIENT_SECRET':os.environ['COMPOSEFLUX_CLIENT_SECRET'],
}
p.write_text(''.join(f'{k}={shlex.quote(v)}\n' for k,v in values.items()))
p.chmod(0o600); os.chown(p,0,0)
PY

refresh_infisical_token
cloud_run=(infisical run --token="$INFISICAL_TOKEN" --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENVIRONMENT" --path="$INFISICAL_SECRET_PATH" --)
"${cloud_run[@]}" ansible-playbook -i 'localhost,' -c local "$repo_dir/ansible/playbooks/enable-gitops.yml"

cat <<DONE

Initialization finished. Configuration and service secrets are stored in Infisical.
The local Infisical connection credential is in $cloud_config (root-only mode 0600).
Keep a protected copy of that credential or enter it again when restoring a new VPS.
DONE
