#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/erresoftware/rpi-monitor.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/rpi-monitor}"
SERVICE_NAME="${SERVICE_NAME:-rpi-monitor}"
NODE_MAJOR="${NODE_MAJOR:-20}"

log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }

is_raspberry_pi() {
  [[ -r /proc/device-tree/model ]] && tr -d '\0' < /proc/device-tree/model | grep -qi 'raspberry'
}

ensure_node() {
  if command -v node >/dev/null 2>&1; then
    return 0
  fi
  log "Installing Node.js ${NODE_MAJOR}..."
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
  sudo apt-get install -y nodejs
}

ensure_pm2() {
  if command -v pm2 >/dev/null 2>&1; then
    return 0
  fi
  log "Installing PM2..."
  sudo npm install -g pm2
}

clone_or_update() {
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    log "Updating existing checkout in ${INSTALL_DIR}"
    git -C "${INSTALL_DIR}" pull --ff-only
  else
    log "Cloning ${REPO_URL} into ${INSTALL_DIR}"
    git clone --depth 1 "${REPO_URL}" "${INSTALL_DIR}"
  fi
}

generate_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    head -c 32 /dev/urandom | xxd -p -c 64
  fi
}

write_env() {
  local env_path="${INSTALL_DIR}/.env"
  if [[ -f "${env_path}" ]]; then
    log ".env already present, skipping generation"
    return 0
  fi
  local token
  token="$(generate_token)"
  cat > "${env_path}" <<ENVEOF
PORT=3002
HOST=0.0.0.0
AUTH_TOKEN=${token}
ENABLE_POWER_ENDPOINTS=false
CACHE_TTL_SECONDS=5
ENVEOF
  chmod 600 "${env_path}"
  log "Generated .env with random AUTH_TOKEN"
  printf '\n  AUTH_TOKEN=%s\n\n' "${token}"
}

install_dependencies() {
  log "Installing npm dependencies..."
  ( cd "${INSTALL_DIR}" && npm ci --omit=dev 2>/dev/null || npm install --omit=dev )
}

start_service() {
  log "Starting service via PM2..."
  if pm2 describe "${SERVICE_NAME}" >/dev/null 2>&1; then
    pm2 restart "${SERVICE_NAME}" --update-env
  else
    pm2 start "${INSTALL_DIR}/src/index.js" --name "${SERVICE_NAME}"
  fi
  pm2 save
}

configure_autostart() {
  log "Configuring PM2 autostart..."
  local cmd
  cmd="$(pm2 startup systemd -u "${USER}" --hp "${HOME}" | tail -1 || true)"
  if [[ "${cmd}" == sudo* ]]; then
    eval "${cmd}" || warn "Autostart configuration returned non-zero status"
  else
    warn "Could not determine pm2 startup command; run 'pm2 startup' manually"
  fi
}

print_summary() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  cat <<SUMMARY

======================================
  Installation complete
======================================

  URL:    http://${ip:-<rpi-ip>}:3002
  Token:  see ${INSTALL_DIR}/.env

  Power endpoints are disabled by default.
  To enable, edit ${INSTALL_DIR}/.env and set:
    ENABLE_POWER_ENDPOINTS=true

  Then add to /etc/sudoers.d/${SERVICE_NAME}:
    ${USER} ALL=(root) NOPASSWD: /sbin/reboot, /sbin/shutdown

  Restart with: pm2 restart ${SERVICE_NAME}

SUMMARY
}

main() {
  echo "======================================"
  echo "  Raspberry Pi Monitor - Installer"
  echo "======================================"

  if ! is_raspberry_pi; then
    err "This script must be run on a Raspberry Pi"
    exit 1
  fi

  log "Refreshing apt index..."
  sudo apt-get update -qq

  ensure_node
  ensure_pm2
  clone_or_update
  install_dependencies
  write_env
  start_service
  configure_autostart
  print_summary
}

main "$@"