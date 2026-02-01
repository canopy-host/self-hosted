#!/usr/bin/env bash
set -euo pipefail

print_banner() {
  cat <<'ART'
              &&& &&  & &&
          && &\/&\|& ()|/ @, &&
          &\/(\/&/&||/& /_/)_&/_&
       &() &\/&|()|/&\/ '%" & ()
      &_\_&&_\ |& |&&/&__%_/_& &&
    &&   && & &| &| /& & % ()& /&&
     ()&_---()&\&\|&&-&&--%---()~
         &&     \|||
                 |||
                 |||
                 |||
           , -=-~  .-^- _
ART
  echo
  echo "welcome 👋"
  echo "thank you for using the canopy install tool"
  echo "note: this is beta software"
  echo
  read -r -p "start the install now? (Y/n): " START_INSTALL_REPLY
  START_INSTALL_REPLY="${START_INSTALL_REPLY:-Y}"
  if [[ ! "${START_INSTALL_REPLY}" =~ ^[Yy]$ ]]; then
    echo "install cancelled"
    exit 0
  fi
  echo
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }; }

is_port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -n -P -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "${port}" >/dev/null 2>&1
    return $?
  fi
  python - <<'PY' "${port}"
import socket, sys
port = int(sys.argv[1])
sock = socket.socket()
try:
  sock.bind(("127.0.0.1", port))
except OSError:
  sys.exit(0)  # in use
else:
  sys.exit(1)  # free
finally:
  sock.close()
PY
}

assert_ports_free() {
  local ports=("$@")
  local in_use=()
  local port
  for port in "${ports[@]}"; do
    if is_port_in_use "${port}"; then
      in_use+=("${port}")
    fi
  done
  if [[ "${#in_use[@]}" -gt 0 ]]; then
    echo "the following ports are already in use: ${in_use[*]}" >&2
    echo "please free these ports or choose different values before continuing." >&2
    exit 1
  fi
}

validate_port_value() {
  local label="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    echo "invalid ${label} port: must be numeric" >&2
    exit 1
  fi
  if (( value < 1024 || value > 65535 )); then
    echo "invalid ${label} port: must be between 1024 and 65535" >&2
    exit 1
  fi
}

parse_compose_ports() {
  local file="$1"
  [[ -f "${file}" ]] || return 1
  rg -o '^[[:space:]]*-[[:space:]]*"?[0-9]+:[0-9]+' "${file}" \
    | awk -F: '{gsub(/[^0-9]/, "", $1); if ($1 != "") print $1}'
}

replace_compose_port() {
  local file="$1"
  local old_port="$2"
  local new_port="$3"
  python - <<'PY' "${file}" "${old_port}" "${new_port}"
import sys
path, old_port, new_port = sys.argv[1], sys.argv[2], sys.argv[3]
old_patterns = [
  f'- "{old_port}:',
  f"- '{old_port}:",
  f"- {old_port}:",
]
new_patterns = [
  f'- "{new_port}:',
  f"- '{new_port}:",
  f"- {new_port}:",
]
with open(path, "r", encoding="utf-8") as f:
  data = f.read()
for old, new in zip(old_patterns, new_patterns):
  data = data.replace(old, new)
with open(path, "w", encoding="utf-8") as f:
  f.write(data)
PY
}

prompt_for_port_change() {
  local label="$1"
  local current="$2"
  local reply
  while true; do
    read -r -p "${label} port ${current} is in use. enter a new port (1024-65535) or press enter to cancel: " reply
    if [[ -z "${reply}" ]]; then
      echo "install cancelled"
      exit 1
    fi
    if [[ ! "${reply}" =~ ^[0-9]+$ ]]; then
      echo "invalid port: must be numeric"
      continue
    fi
    if (( reply < 1024 || reply > 65535 )); then
      echo "invalid port: must be between 1024 and 65535"
      continue
    fi
    echo "${reply}"
    return 0
  done
}

read_env_value() {
  local key="$1"
  local file="$2"
  [[ -f "$file" ]] || return 1
  local value
  value="$(awk -F= -v k="$key" '$1==k {print substr($0, index($0,$2)); exit}' "$file")"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

print_banner

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE_HOST="${ENV_FILE_HOST:-.env.local}"
ENV_FILE_DOCKER="${ENV_FILE_DOCKER:-.env.docker}"
START_API="${START_API:-true}"
DEFAULT_CANOPY_API_PORT="${DEFAULT_CANOPY_API_PORT:-3000}"
CANOPY_STORAGE_ROOT="${CANOPY_STORAGE_ROOT:-$HOME/.canopy/storage}"
DOKKU_SETUP="${DOKKU_SETUP:-true}"
IMAGE_USER="${IMAGE_USER:-thecanopycorp}"
IMAGE_TAG="${IMAGE_TAG:-1.0}"
CANOPY_WEB_PORT="${CANOPY_WEB_PORT:-3000}"
VAULT_PORT="${VAULT_PORT:-8200}"
DOKKU_SSH_PORT="${DOKKU_SSH_PORT:-3022}"
DOKKU_HTTP_PORT="${DOKKU_HTTP_PORT:-8080}"
DOKKU_HTTPS_PORT="${DOKKU_HTTPS_PORT:-8443}"

API_IMAGE="${IMAGE_USER}/api:${IMAGE_TAG}"
APP_IMAGE="${IMAGE_USER}/app:${IMAGE_TAG}"

existing_port="$(read_env_value PRODUCTION_API_SERVICE_PORT "${ENV_FILE_HOST}" || true)"
existing_domain="$(read_env_value API_SERVICE_DOMAIN "${ENV_FILE_HOST}" || true)"
existing_gh_client_id="$(read_env_value PRODUCTION_GITHUB_CLIENT_ID "${ENV_FILE_HOST}" || true)"
existing_gh_client_secret="$(read_env_value PRODUCTION_GITHUB_CLIENT_SECRET "${ENV_FILE_HOST}" || true)"
existing_supabase_url="$(read_env_value SUPABASE_URL "${ENV_FILE_HOST}" || true)"
existing_supabase_key="$(read_env_value SUPABASE_SERVICE_ROLE_KEY "${ENV_FILE_HOST}" || true)"
existing_anon_key="$(read_env_value SUPABASE_ANON_KEY "${ENV_FILE_HOST}" || true)"
existing_jwt_secret="$(read_env_value SUPABASE_JWT_SECRET "${ENV_FILE_HOST}" || true)"
existing_node_env="$(read_env_value NODE_ENV "${ENV_FILE_HOST}" || true)"

CANOPY_API_PORT_DEFAULT="${existing_port:-${DEFAULT_CANOPY_API_PORT}}"
NODE_ENV_DEFAULT="${existing_node_env:-production}"

echo
echo "install settings"
echo " - ENV_FILE_HOST=${ENV_FILE_HOST}"
echo " - ENV_FILE_DOCKER=${ENV_FILE_DOCKER}"
echo " - START_API=${START_API}"
echo " - DEFAULT_CANOPY_API_PORT=${DEFAULT_CANOPY_API_PORT}"
echo " - CANOPY_STORAGE_ROOT=${CANOPY_STORAGE_ROOT}"
echo " - DOKKU_SETUP=${DOKKU_SETUP}"
echo " - API_IMAGE=${API_IMAGE}"
echo " - APP_IMAGE=${APP_IMAGE}"
echo " - CANOPY_WEB_PORT=${CANOPY_WEB_PORT}"
echo " - VAULT_PORT=${VAULT_PORT}"
echo " - DOKKU_SSH_PORT=${DOKKU_SSH_PORT}"
echo " - DOKKU_HTTP_PORT=${DOKKU_HTTP_PORT}"
echo " - DOKKU_HTTPS_PORT=${DOKKU_HTTPS_PORT}"
echo

need docker

echo
read -r -p "do you need to login to Docker Hub? (y/N): " DOCKER_LOGIN_REPLY
DOCKER_LOGIN_REPLY="${DOCKER_LOGIN_REPLY:-N}"
if [[ "${DOCKER_LOGIN_REPLY}" =~ ^[Yy]$ ]]; then
  echo "logging into Docker Hub..."
  docker login
fi

REUSE_CONFIG="false"
if [[ -f "${ENV_FILE_HOST}" ]]; then
  read -r -p "reuse existing ${ENV_FILE_HOST} values and skip prompts? (Y/n): " REUSE_CONFIG
  REUSE_CONFIG="${REUSE_CONFIG:-Y}"
fi

if [[ "${REUSE_CONFIG}" =~ ^[Yy]$ ]]; then
  CANOPY_API_PORT="${CANOPY_API_PORT_DEFAULT}"
  API_DOMAIN="${existing_domain}"
  GITHUB_CLIENT_ID="${existing_gh_client_id}"
  GITHUB_CLIENT_SECRET="${existing_gh_client_secret}"
  SUPABASE_URL="${existing_supabase_url}"
  SUPABASE_SERVICE_ROLE_KEY="${existing_supabase_key}"
  SUPABASE_ANON_KEY="${existing_anon_key}"
  SUPABASE_JWT_SECRET="${existing_jwt_secret}"
  NODE_ENV="${NODE_ENV_DEFAULT}"
else
  read -r -p "which port should the canopy API run on? [${CANOPY_API_PORT_DEFAULT}]: " CANOPY_API_PORT
  CANOPY_API_PORT="${CANOPY_API_PORT:-${CANOPY_API_PORT_DEFAULT}}"

  echo
  while true; do
    read -r -p "is this a production or development build? [${NODE_ENV_DEFAULT}]: " NODE_ENV
    NODE_ENV="${NODE_ENV:-${NODE_ENV_DEFAULT}}"
    if [[ "${NODE_ENV}" == "production" || "${NODE_ENV}" == "development" ]]; then
      break
    fi
    echo "invalid environment: enter 'production' or 'development'"
  done

  echo
  read -r -p "api domain (example: api.example.com) [${existing_domain}]: " API_DOMAIN
  API_DOMAIN="${API_DOMAIN:-${existing_domain}}"

  echo
  read -r -p "github OAuth client id${existing_gh_client_id:+ [${existing_gh_client_id}]}: " GITHUB_CLIENT_ID
  GITHUB_CLIENT_ID="${GITHUB_CLIENT_ID:-${existing_gh_client_id}}"

  read -r -p "github OAuth client secret${existing_gh_client_secret:+ [set]}: " GITHUB_CLIENT_SECRET
  GITHUB_CLIENT_SECRET="${GITHUB_CLIENT_SECRET:-${existing_gh_client_secret}}"

  echo
  read -r -p "supabase url${existing_supabase_url:+ [${existing_supabase_url}]}: " SUPABASE_URL
  SUPABASE_URL="${SUPABASE_URL:-${existing_supabase_url}}"

  read -r -p "supabase service role key${existing_supabase_key:+ [set]}: " SUPABASE_SERVICE_ROLE_KEY
  SUPABASE_SERVICE_ROLE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-${existing_supabase_key}}"

  read -r -p "supabase anon key${existing_anon_key:+ [set]}: " SUPABASE_ANON_KEY
  SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-${existing_anon_key}}"

  read -r -p "supabase jwt secret${existing_jwt_secret:+ [set]}: " SUPABASE_JWT_SECRET
  SUPABASE_JWT_SECRET="${SUPABASE_JWT_SECRET:-${existing_jwt_secret}}"
fi

validate_port_value "canopy api" "${CANOPY_API_PORT}"
validate_port_value "canopy web" "${CANOPY_WEB_PORT}"
validate_port_value "vault" "${VAULT_PORT}"
if [[ "${DOKKU_SETUP}" == "true" ]]; then
  validate_port_value "dokku ssh" "${DOKKU_SSH_PORT}"
  validate_port_value "dokku http" "${DOKKU_HTTP_PORT}"
  validate_port_value "dokku https" "${DOKKU_HTTPS_PORT}"
fi

ports_to_check=()
if [[ -f docker-compose.yml ]]; then
  while IFS= read -r port; do
    ports_to_check+=("${port}")
  done < <(parse_compose_ports docker-compose.yml || true)
else
  if [[ "${START_API}" == "true" ]]; then
    ports_to_check+=("${CANOPY_API_PORT}" "${CANOPY_WEB_PORT}" "${VAULT_PORT}")
  fi
  if [[ "${DOKKU_SETUP}" == "true" ]]; then
    ports_to_check+=("${DOKKU_SSH_PORT}" "${DOKKU_HTTP_PORT}" "${DOKKU_HTTPS_PORT}")
  fi
fi

if [[ "${#ports_to_check[@]}" -gt 0 ]]; then
  unique_ports=()
  for port in "${ports_to_check[@]}"; do
    if [[ " ${unique_ports[*]} " != *" ${port} "* ]]; then
      unique_ports+=("${port}")
    fi
  done
  echo "checking required ports are available..."
  in_use_ports=()
  for port in "${unique_ports[@]}"; do
    if is_port_in_use "${port}"; then
      in_use_ports+=("${port}")
    fi
  done
  if [[ "${#in_use_ports[@]}" -gt 0 ]]; then
    for port in "${in_use_ports[@]}"; do
      case "${port}" in
        "${CANOPY_API_PORT}")
          new_port="$(prompt_for_port_change "canopy api" "${port}")"
          CANOPY_API_PORT="${new_port}"
          ;;
        "${CANOPY_WEB_PORT}")
          new_port="$(prompt_for_port_change "canopy web" "${port}")"
          CANOPY_WEB_PORT="${new_port}"
          ;;
        "${VAULT_PORT}")
          new_port="$(prompt_for_port_change "vault" "${port}")"
          VAULT_PORT="${new_port}"
          ;;
        "${DOKKU_SSH_PORT}")
          new_port="$(prompt_for_port_change "dokku ssh" "${port}")"
          DOKKU_SSH_PORT="${new_port}"
          ;;
        "${DOKKU_HTTP_PORT}")
          new_port="$(prompt_for_port_change "dokku http" "${port}")"
          DOKKU_HTTP_PORT="${new_port}"
          ;;
        "${DOKKU_HTTPS_PORT}")
          new_port="$(prompt_for_port_change "dokku https" "${port}")"
          DOKKU_HTTPS_PORT="${new_port}"
          ;;
        *)
          echo "port ${port} is in use and is not configurable by this installer." >&2
          echo "please free it before continuing." >&2
          exit 1
          ;;
      esac
      if [[ -f docker-compose.yml ]]; then
        replace_compose_port docker-compose.yml "${port}" "${new_port}"
      fi
    done
  fi
  final_ports=()
  if [[ -f docker-compose.yml ]]; then
    while IFS= read -r port; do
      final_ports+=("${port}")
    done < <(parse_compose_ports docker-compose.yml || true)
  else
    if [[ "${START_API}" == "true" ]]; then
      final_ports+=("${CANOPY_API_PORT}" "${CANOPY_WEB_PORT}" "${VAULT_PORT}")
    fi
    if [[ "${DOKKU_SETUP}" == "true" ]]; then
      final_ports+=("${DOKKU_SSH_PORT}" "${DOKKU_HTTP_PORT}" "${DOKKU_HTTPS_PORT}")
    fi
  fi
  if [[ "${#final_ports[@]}" -gt 0 ]]; then
    assert_ports_free "${final_ports[@]}"
  fi
  echo "all required ports are available"
fi

mkdir -p "${CANOPY_STORAGE_ROOT}/supabase" "${CANOPY_STORAGE_ROOT}/api" "${CANOPY_STORAGE_ROOT}/vault" "${CANOPY_STORAGE_ROOT}/app"

echo "storage directories created under ${CANOPY_STORAGE_ROOT}"

write_env_file() {
  local envFile="${1-}"
  local canopyApiPort="${2-}"
  local apiDomain="${3-}"
  local githubClientId="${4-}"
  local githubClientSecret="${5-}"
  local supabaseUrl="${6-}"
  local supabaseServiceRoleKey="${7-}"
  local supabaseAnonKey="${8-}"
  local supabaseJwtSecret="${9-}"
  local storageRoot="${10-}"
  local nodeEnv="${11-}"

  if [[ "$#" -lt 11 ]]; then
    echo "write_env_file expects 11 arguments, got $#." >&2
    exit 1
  fi

  cat > "${envFile}" <<EOF
NODE_ENV='${nodeEnv}'
SUPABASE_URL='${supabaseUrl}'
SUPABASE_API_URL='${supabaseUrl}'
SUPABASE_SERVICE_ROLE_KEY='${supabaseServiceRoleKey}'
SUPABASE_SERVICE_KEY='${supabaseServiceRoleKey}'
SUPABASE_KEY='${supabaseServiceRoleKey}'
SUPABASE_ANON_KEY='${supabaseAnonKey}'
SUPABASE_JWT_SECRET='${supabaseJwtSecret}'
ANON_KEY='${supabaseAnonKey}'
SERVICE_ROLE_KEY='${supabaseServiceRoleKey}'
JWT_SECRET='${supabaseJwtSecret}'
PRODUCTION_API_SERVICE_PORT='${canopyApiPort}'
DEVELOPMENT_API_SERVICE_PORT='${canopyApiPort}'
API_SERVICE_DOMAIN='${apiDomain:-localhost}'
PRODUCTION_GITHUB_CLIENT_ID='${githubClientId}'
PRODUCTION_GITHUB_CLIENT_SECRET='${githubClientSecret}'
DEVELOPMENT_GITHUB_CLIENT_ID='${githubClientId}'
DEVELOPMENT_GITHUB_CLIENT_SECRET='${githubClientSecret}'
VAULT_ADDR='http://vault:8200'
VAULT_TOKEN='root'
CANOPY_STORAGE_ROOT='${storageRoot}'
EOF
  echo "wrote ${envFile}"
}

write_env_file "${ENV_FILE_HOST}" "${CANOPY_API_PORT}" "${API_DOMAIN}" "${GITHUB_CLIENT_ID}" "${GITHUB_CLIENT_SECRET}" "${SUPABASE_URL}" "${SUPABASE_SERVICE_ROLE_KEY}" "${SUPABASE_ANON_KEY}" "${SUPABASE_JWT_SECRET}" "${CANOPY_STORAGE_ROOT}" "${NODE_ENV}"
write_env_file "${ENV_FILE_DOCKER}" "${CANOPY_API_PORT}" "${API_DOMAIN}" "${GITHUB_CLIENT_ID}" "${GITHUB_CLIENT_SECRET}" "${SUPABASE_URL}" "${SUPABASE_SERVICE_ROLE_KEY}" "${SUPABASE_ANON_KEY}" "${SUPABASE_JWT_SECRET}" "${CANOPY_STORAGE_ROOT}" "${NODE_ENV}"

if [[ ! -f docker-compose.yml ]]; then
  cat > docker-compose.yml <<YAML
services:
  vault:
    image: hashicorp/vault:1.16
    platform: linux/amd64
    cap_add:
      - IPC_LOCK
    ports:
      - "${VAULT_PORT}:8200"
    environment:
      VAULT_DEV_ROOT_TOKEN_ID: root
      VAULT_DEV_LISTEN_ADDRESS: "0.0.0.0:8200"
    command: ["vault", "server", "-dev"]
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8200/v1/sys/health"]
      interval: 5s
      timeout: 2s
      retries: 30
    volumes:
      - ${CANOPY_STORAGE_ROOT:-${HOME}/.canopy/storage}/vault:/vault/file
      - ${CANOPY_STORAGE_ROOT:-${HOME}/.canopy/storage}/vault:/data

  canopy-api:
    image: ${API_IMAGE}
    platform: linux/amd64
    ports:
      - "${PRODUCTION_API_SERVICE_PORT:-3000}:${PRODUCTION_API_SERVICE_PORT:-3000}"
    env_file:
      - .env.docker
    environment:
      NODE_ENV: "${NODE_ENV:-production}"
      PRODUCTION_API_SERVICE_PORT: "${PRODUCTION_API_SERVICE_PORT:-3000}"
      RUN_MIGRATIONS: "false"
      RUN_SEEDS: "false"
    depends_on:
      vault:
        condition: service_healthy
    volumes:
      - ${CANOPY_STORAGE_ROOT:-${HOME}/.canopy/storage}/api:/app/storage

  canopy-web:
    image: ${APP_IMAGE}
    platform: linux/amd64
    ports:
      - "${CANOPY_WEB_PORT}:3000"
    environment:
      NODE_ENV: "${NODE_ENV:-production}"
      PORT: 3000
      NEXT_PUBLIC_BASE_URL: "http://localhost:${PRODUCTION_API_SERVICE_PORT:-3000}"
    volumes:
      - ${CANOPY_STORAGE_ROOT:-${HOME}/.canopy/storage}/app:/app/storage

  dokku:
    image: dokku/dokku:0.37.5
    platform: linux/amd64
    container_name: dokku
    ports:
      - "${DOKKU_SSH_PORT}:22"
      - "${DOKKU_HTTP_PORT}:80"
      - "${DOKKU_HTTPS_PORT}:443"
    volumes:
      - dokku-data:/mnt/dokku
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      DOKKU_HOSTNAME: "dokku.local"
      DOKKU_HOST_ROOT: "/var/lib/dokku/home/dokku"
      DOKKU_LIB_HOST_ROOT: "/var/lib/dokku/var/lib/dokku"
      DOKKU_SKIP_APP_REBUILD: "true"
    privileged: true

  dokku-init:
    image: dokku/dokku:0.37.5
    platform: linux/amd64
    depends_on:
      - dokku
    environment:
      DOKKU_HOSTNAME: "dokku.local"
      DOKKU_SSH_KEY_PATH: "/keys/id_rsa.pub"
    volumes:
      - dokku-data:/mnt/dokku
      - ./dokku-init.sh:/usr/local/bin/dokku-init.sh:ro
      - ~/.ssh:/keys:ro
    entrypoint: ["/bin/bash", "-lc", "dokku-init.sh"]

volumes:
  dokku-data:
YAML
  echo "wrote docker-compose.yml"
fi

if [[ ! -f dokku-init.sh ]]; then
  cat > dokku-init.sh <<'DOC'
#!/usr/bin/env bash
set -euo pipefail

HOSTNAME="${DOKKU_HOSTNAME:-dokku.local}"
SSH_KEY_PATH="${DOKKU_SSH_KEY_PATH:-}"

echo "Setting Dokku global domain to ${HOSTNAME}"
dokku domains:set-global "${HOSTNAME}"

if [ -n "${SSH_KEY_PATH}" ] && [ -f "${SSH_KEY_PATH}" ]; then
  echo "Adding Dokku SSH key from ${SSH_KEY_PATH}"
  dokku ssh-keys:add admin "${SSH_KEY_PATH}"
else
  echo "Skipping SSH key add (set DOKKU_SSH_KEY_PATH to a mounted public key file)."
fi
DOC
  chmod +x dokku-init.sh
  echo "wrote dokku-init.sh"
fi

if [[ "${START_API}" == "true" ]]; then
  echo "starting canopy services..."
  echo "pulling latest images..."
  docker compose pull vault canopy-api canopy-web
  docker compose up -d vault canopy-api canopy-web
else
  echo "START_API=false; skipping canopy-api + canopy-web"
fi

if [[ "${DOKKU_SETUP}" == "true" ]]; then
  echo "starting dokku..."
  echo "pulling dokku images..."
  docker compose pull dokku dokku-init
  docker compose up -d dokku
  echo "running dokku init..."
  docker compose run --rm dokku-init || true
  echo "dokku setup complete"
else
  echo "DOKKU_SETUP=false; skipping dokku"
fi

echo
echo "install finished"
echo "api is running on port ${CANOPY_API_PORT}"
echo "storage root: ${CANOPY_STORAGE_ROOT}"
