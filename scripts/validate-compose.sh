#!/usr/bin/env bash
set -Eeuo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v docker >/dev/null || { echo "docker CLI with Compose v2 is required" >&2; exit 1; }

while IFS= read -r compose_file; do
  temp_dir="$(mktemp -d)"
  temp_env="$temp_dir/compose.env"
  trap 'rm -rf "$temp_dir"' EXIT
  if [[ "$compose_file" == */stacks/composeflux/compose.yaml ]]; then
    cat >"$temp_dir/composeflux.env" <<'ENV'
INFISICAL_DOMAIN=https://app.infisical.com
INFISICAL_ENVIRONMENT=prod
INFISICAL_PROJECT_ID=validation
INFISICAL_CLIENT_ID=validation
INFISICAL_CLIENT_SECRET=validation
INFISICAL_SECRET_PATH=/
ENV
  fi
  python3 - "$compose_file" "$temp_env" "$temp_dir" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
keys = sorted(set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)", source)))
with open(sys.argv[2], "w") as out:
    for key in keys:
        if key.endswith("_PORT"):
            value = "8090"
        elif key.endswith("_DIR") or key.endswith("_PATH"):
            value = "/tmp/compose-validation"
            if key == "BOOTSTRAP_DIR":
                value = sys.argv[3]
        elif key.endswith("_URL") or key.endswith("_URI"):
            value = "https://validation.example.invalid"
        elif key.endswith("_DOMAIN"):
            value = "validation.example.invalid"
        elif key.endswith("_ENABLED"):
            value = "false"
        else:
            value = "validation-value"
        out.write(f"{key}={value}\n")
PY
  echo "Validating ${compose_file#"$root_dir"/}"
  docker compose --env-file "$temp_env" -f "$compose_file" config --quiet
  rm -rf "$temp_dir"
  trap - EXIT
done < <(find "$root_dir/stacks" -mindepth 2 -maxdepth 2 -name compose.yaml -type f -print | sort)
