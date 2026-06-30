#!/usr/bin/env bash
# Self-service SuperHealth installer/upgrader for customer Ubuntu servers.
#
# Customer-facing commands:
#   bash customer_superhealth.sh install
#   bash customer_superhealth.sh upgrade
#   bash customer_superhealth.sh rollback
#   bash customer_superhealth.sh status
#   superhealth upgrade
#
# The script does not require inbound SSH access. It runs entirely on the
# customer server and uses a read-only GitHub deploy key supplied by the operator.

set -euo pipefail

DEFAULT_DATA_DIR="${SUPERHEALTH_DATA_DIR:-$HOME/.superhealth}"
CONFIG_FILE="${SUPERHEALTH_INSTALLER_CONFIG:-$DEFAULT_DATA_DIR/installer.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  set +a
fi

REPO_SSH_URL="${SUPERHEALTH_REPO_SSH_URL:-git@github.com-superhealth:chasezjj/superHealth.git}"
BRANCH="${SUPERHEALTH_BRANCH:-main}"
INSTALL_ROOT="${SUPERHEALTH_INSTALL_ROOT:-$HOME/superHealth}"
DATA_DIR="${SUPERHEALTH_DATA_DIR:-$HOME/.superhealth}"
DEPLOY_KEY_PATH="${SUPERHEALTH_DEPLOY_KEY_PATH:-$HOME/.ssh/superhealth-deploy}"
DASHBOARD_PORT="${DASHBOARD_PORT:-8501}"
VITALS_PORT="${SUPERHEALTH_VITALS_PORT:-8506}"
INSTALLER_URL="${SUPERHEALTH_INSTALLER_URL:-}"
COMMAND_PATH="${SUPERHEALTH_COMMAND_PATH:-$HOME/.local/bin/superhealth}"
SCRIPT_PATH="${SUPERHEALTH_SCRIPT_PATH:-${BASH_SOURCE[0]}}"
CONFIG_FILE="${SUPERHEALTH_INSTALLER_CONFIG:-$DATA_DIR/installer.env}"

SOURCE_DIR="$INSTALL_ROOT/source"
RELEASES_DIR="$INSTALL_ROOT/releases"
CURRENT_LINK="$INSTALL_ROOT/current"
PREVIOUS_VERSION_FILE="$INSTALL_ROOT/.previous_version"
BACKUP_DIR="$DATA_DIR/backups"

log() {
  printf '\n[superhealth] %s\n' "$*"
}

usage() {
  cat <<EOF
Usage: bash customer_superhealth.sh <command>

Commands:
  install       First install: system packages, deploy key, clone, start services, validate.
  upgrade       Pull latest code, backup data, deploy new release, validate, auto-rollback on failure.
  rollback      Switch back to the previous release. Prompts before restoring latest data backup.
  backup        Create a local backup of SuperHealth data/config.
  status        Show release and service status.
  validate      Verify layout, Python imports, services, and HTTP health endpoints.

Environment:
  SUPERHEALTH_BRANCH             Git branch to deploy. Default: $BRANCH
  SUPERHEALTH_REPO_SSH_URL       Repo SSH URL. Default: $REPO_SSH_URL
  SUPERHEALTH_INSTALL_ROOT       Install root. Default: $INSTALL_ROOT
  SUPERHEALTH_DATA_DIR           Data/config dir. Default: $DATA_DIR
  SUPERHEALTH_DEPLOY_KEY_B64     Optional base64-encoded private deploy key.
  SUPERHEALTH_DEPLOY_KEY_URL     Optional one-time URL returning base64 private deploy key.
  SUPERHEALTH_INSTALLER_URL      Optional public URL used to refresh the local superhealth command.

EOF
}

write_config_line() {
  local key="$1" value="$2"
  printf '%s=%q\n' "$key" "$value"
}

persist_installer_config() {
  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  {
    write_config_line SUPERHEALTH_REPO_SSH_URL "$REPO_SSH_URL"
    write_config_line SUPERHEALTH_BRANCH "$BRANCH"
    write_config_line SUPERHEALTH_INSTALL_ROOT "$INSTALL_ROOT"
    write_config_line SUPERHEALTH_DATA_DIR "$DATA_DIR"
    write_config_line SUPERHEALTH_DEPLOY_KEY_PATH "$DEPLOY_KEY_PATH"
    write_config_line DASHBOARD_PORT "$DASHBOARD_PORT"
    write_config_line SUPERHEALTH_VITALS_PORT "$VITALS_PORT"
    write_config_line SUPERHEALTH_INSTALLER_URL "$INSTALLER_URL"
  } >"$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

install_local_command() {
  persist_installer_config
  mkdir -p "$(dirname "$COMMAND_PATH")"
  if [[ ! -f "$SCRIPT_PATH" ]]; then
    echo "Cannot install local command because script path is not a file: $SCRIPT_PATH" >&2
    return
  fi
  cp "$SCRIPT_PATH" "$COMMAND_PATH"
  chmod +x "$COMMAND_PATH"
  log "Installed local command: $COMMAND_PATH"

  case ":$PATH:" in
    *":$(dirname "$COMMAND_PATH"):"*) ;;
    *) echo "Tip: add $(dirname "$COMMAND_PATH") to PATH, or run $COMMAND_PATH directly." >&2 ;;
  esac
}

require_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then
    echo "Cannot detect OS: /etc/os-release not found" >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "This installer is tested for Ubuntu; detected ID=${ID:-unknown}" >&2
    exit 1
  fi
}

require_sudo() {
  log "Checking sudo access"
  if sudo -n true 2>/dev/null; then
    return
  fi
  if [[ -t 0 ]]; then
    sudo -v
    return
  fi
  echo "sudo requires a password, but this installer is not running in an interactive terminal." >&2
  echo "Run the install command directly in the server terminal, or configure passwordless sudo for this user." >&2
  exit 1
}

install_system_dependencies() {
  log "Installing Ubuntu system dependencies"
  sudo apt-get update

  local packages=(
    git curl wget ca-certificates openssh-client jq tar gzip \
    python3 python3-pip python3-full python3-venv \
    fonts-wqy-zenhei fonts-wqy-microhei \
    libglib2.0-0 libnss3 libnspr4 \
    libatk1.0-0 \
    libdrm2 libxkbcommon0 libxcomposite1 \
    libxdamage1 libxfixes3 libxrandr2 \
    libgbm1 libpango-1.0-0 libcairo2 \
  )

  add_first_available_package() {
    local candidate
    for candidate in "$@"; do
      if apt-cache show "$candidate" >/dev/null 2>&1; then
        packages+=("$candidate")
        return
      fi
    done
    echo "None of these packages are available: $*" >&2
  }

  add_first_available_package libatk-bridge2.0-0t64 libatk-bridge2.0-0
  add_first_available_package libcups2t64 libcups2
  add_first_available_package libasound2t64 libasound2
  add_first_available_package libatspi2.0-0t64 libatspi2.0-0

  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

enable_user_linger() {
  if command -v loginctl >/dev/null 2>&1; then
    log "Enabling user service persistence"
    sudo loginctl enable-linger "$(id -un)" || true
  fi
}

configure_pip_mirror() {
  log "Configuring Tencent Cloud pip mirror"
  python3 -m pip config set global.index-url https://mirrors.cloud.tencent.com/pypi/simple >/dev/null || true
}

read_deploy_key() {
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  if [[ -f "$DEPLOY_KEY_PATH" ]]; then
    chmod 600 "$DEPLOY_KEY_PATH"
    if grep -q "PRIVATE KEY" "$DEPLOY_KEY_PATH"; then
      return
    fi
    echo "Existing deploy key is incomplete or invalid; rewriting: $DEPLOY_KEY_PATH" >&2
    rm -f "$DEPLOY_KEY_PATH"
  fi

  if [[ -n "${SUPERHEALTH_DEPLOY_KEY_B64:-}" ]]; then
    local tmp_key
    tmp_key="$(mktemp "${DEPLOY_KEY_PATH}.tmp.XXXXXX")"
    printf '%s' "$SUPERHEALTH_DEPLOY_KEY_B64" | base64 -d >"$tmp_key"
    if ! grep -q "PRIVATE KEY" "$tmp_key"; then
      rm -f "$tmp_key"
      echo "Decoded deploy key does not look like a private key." >&2
      exit 1
    fi
    mv "$tmp_key" "$DEPLOY_KEY_PATH"
    chmod 600 "$DEPLOY_KEY_PATH"
    return
  fi

  if [[ -n "${SUPERHEALTH_DEPLOY_KEY_URL:-}" ]]; then
    local tmp_b64 tmp_key
    tmp_b64="$(mktemp "${DEPLOY_KEY_PATH}.b64.XXXXXX")"
    tmp_key="$(mktemp "${DEPLOY_KEY_PATH}.tmp.XXXXXX")"
    curl -fsSL "$SUPERHEALTH_DEPLOY_KEY_URL" -o "$tmp_b64"
    base64 -d <"$tmp_b64" >"$tmp_key"
    rm -f "$tmp_b64"
    if ! grep -q "PRIVATE KEY" "$tmp_key"; then
      rm -f "$tmp_key"
      echo "Downloaded deploy key does not look like a private key." >&2
      exit 1
    fi
    mv "$tmp_key" "$DEPLOY_KEY_PATH"
    chmod 600 "$DEPLOY_KEY_PATH"
    return
  fi

  cat <<EOF

Paste the read-only SuperHealth deploy private key below.
End the paste by typing this marker on its own line:

END_SUPERHEALTH_DEPLOY_KEY

EOF

  : >"$DEPLOY_KEY_PATH"
  local line
  while IFS= read -r line; do
    [[ "$line" == "END_SUPERHEALTH_DEPLOY_KEY" ]] && break
    printf '%s\n' "$line" >>"$DEPLOY_KEY_PATH"
  done
  chmod 600 "$DEPLOY_KEY_PATH"

  if ! grep -q "PRIVATE KEY" "$DEPLOY_KEY_PATH"; then
    echo "Deploy key does not look like a private key: $DEPLOY_KEY_PATH" >&2
    exit 1
  fi
}

configure_ssh_alias() {
  log "Configuring GitHub SSH alias"
  touch "$HOME/.ssh/config"
  chmod 600 "$HOME/.ssh/config"
  if grep -q '^Host github\.com-superhealth$' "$HOME/.ssh/config"; then
    cp "$HOME/.ssh/config" "$HOME/.ssh/config.bak.$(date +%Y%m%d%H%M%S)"
    awk '
      /^Host github\.com-superhealth$/ { skip = 1; next }
      /^Host / { skip = 0 }
      !skip { print }
    ' "$HOME/.ssh/config" >"$HOME/.ssh/config.tmp"
    mv "$HOME/.ssh/config.tmp" "$HOME/.ssh/config"
  fi

  cat >>"$HOME/.ssh/config" <<EOF

Host github.com-superhealth
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile $DEPLOY_KEY_PATH
    IdentitiesOnly yes
EOF
}

sync_source_repo() {
  log "Syncing SuperHealth source"
  mkdir -p "$INSTALL_ROOT"
  if [[ -d "$SOURCE_DIR/.git" ]]; then
    git -C "$SOURCE_DIR" fetch origin "$BRANCH"
    git -C "$SOURCE_DIR" checkout -B "$BRANCH" "origin/$BRANCH"
  else
    if [[ -e "$SOURCE_DIR" ]]; then
      echo "Removing incomplete source directory: $SOURCE_DIR" >&2
      rm -rf "$SOURCE_DIR"
    fi
    git clone --branch "$BRANCH" "$REPO_SSH_URL" "$SOURCE_DIR"
  fi
}

current_version() {
  readlink "$CURRENT_LINK" 2>/dev/null | sed 's#^releases/##' || true
}

build_release_from_source() {
  local commit version release_dir
  commit="$(git -C "$SOURCE_DIR" rev-parse --short=12 HEAD)"
  version="$(date +%Y%m%d-%H%M%S)-${commit}"
  release_dir="$RELEASES_DIR/$version"

  mkdir -p "$RELEASES_DIR"
  rm -rf "$release_dir"
  mkdir -p "$release_dir"
  git -C "$SOURCE_DIR" archive --format=tar HEAD | tar -xf - -C "$release_dir"
  printf '%s\n' "$version"
}

stop_services() {
  if [[ -x "$CURRENT_LINK/scripts/manage_service.sh" ]]; then
    (cd "$CURRENT_LINK" && bash scripts/manage_service.sh stop dashboard || true)
    (cd "$CURRENT_LINK" && bash scripts/manage_service.sh stop vitals_receiver || true)
  fi
}

start_services() {
  cd "$CURRENT_LINK"
  DASHBOARD_PORT="$DASHBOARD_PORT" bash scripts/manage_service.sh start dashboard
  SUPERHEALTH_VITALS_PORT="$VITALS_PORT" bash scripts/manage_service.sh start vitals_receiver
  bash scripts/manage_service.sh schedule daily_pipeline 7 0
  bash scripts/manage_service.sh schedule weekly_pipeline 20 30 0
}

wait_for_url() {
  local url="$1" label="$2"
  local attempt
  for attempt in $(seq 1 30); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "$label is reachable"
      return 0
    fi
    sleep 2
  done
  echo "$label did not become reachable: $url" >&2
  return 1
}

activate_release() {
  local version="$1"
  if [[ ! -d "$RELEASES_DIR/$version" ]]; then
    echo "Release not found: $version" >&2
    exit 1
  fi
  mkdir -p "$INSTALL_ROOT"
  if [[ -e "$CURRENT_LINK" && ! -L "$CURRENT_LINK" ]]; then
    echo "Replacing non-symlink current path: $CURRENT_LINK" >&2
    rm -rf "$CURRENT_LINK"
  fi
  ln -sfn "releases/$version" "$CURRENT_LINK"
}

backup_data() {
  log "Creating backup"
  mkdir -p "$BACKUP_DIR"
  local backup="$BACKUP_DIR/superhealth-$(date +%Y%m%d-%H%M%S).tar.gz"
  mkdir -p "$DATA_DIR"
  tar -czf "$backup" \
    --exclude="$BACKUP_DIR" \
    "$DATA_DIR" \
    "$CURRENT_LINK" \
    "$PREVIOUS_VERSION_FILE" 2>/dev/null || true
  printf '%s\n' "$backup"
}

restore_backup() {
  local backup="$1"
  if [[ ! -f "$backup" ]]; then
    echo "Backup not found: $backup" >&2
    exit 1
  fi
  log "Restoring backup: $backup"
  tar -xzf "$backup" -C /
}

validate_installation() {
  log "Validating SuperHealth"
  test -L "$CURRENT_LINK"
  test -f "$CURRENT_LINK/pyproject.toml"
  test -x "$CURRENT_LINK/scripts/manage_service.sh"

  cd "$CURRENT_LINK"
  venv/bin/python3 -c "import superhealth.dashboard.app, superhealth.api.vitals_receiver, superhealth.daily_pipeline, superhealth.weekly_pipeline"
  bash scripts/manage_service.sh status dashboard
  bash scripts/manage_service.sh status vitals_receiver
  bash scripts/manage_service.sh status daily_pipeline
  bash scripts/manage_service.sh status weekly_pipeline
  if systemctl --user >/dev/null 2>&1; then
    systemctl --user is-enabled superhealth-daily-pipeline.timer >/dev/null
    systemctl --user is-enabled superhealth-weekly-pipeline.timer >/dev/null
  fi
  wait_for_url "http://127.0.0.1:${DASHBOARD_PORT}/" "dashboard"
  wait_for_url "http://127.0.0.1:${VITALS_PORT}/health" "vitals receiver"
  log "Validation passed"
}

install_flow() {
  require_ubuntu
  require_sudo
  install_system_dependencies
  enable_user_linger
  configure_pip_mirror
  read_deploy_key
  configure_ssh_alias
  install_local_command
  sync_source_repo
  local version
  version="$(build_release_from_source)"
  stop_services
  activate_release "$version"
  start_services
  validate_installation
  log "Installed version: $version"
}

upgrade_flow() {
  require_ubuntu
  require_sudo
  install_system_dependencies
  enable_user_linger
  configure_pip_mirror
  read_deploy_key
  configure_ssh_alias
  install_local_command

  local previous backup version
  previous="$(current_version)"
  [[ -n "$previous" ]] && printf '%s\n' "$previous" >"$PREVIOUS_VERSION_FILE"
  backup="$(backup_data)"

  sync_source_repo
  version="$(build_release_from_source)"

  if ! (
    stop_services
    activate_release "$version"
    start_services
    validate_installation
  ); then
    echo "Upgrade failed; rolling back to previous release: ${previous:-none}" >&2
    if [[ -n "$previous" ]]; then
      stop_services || true
      activate_release "$previous"
      start_services || true
    fi
    echo "Data backup created before upgrade: $backup" >&2
    exit 1
  fi

  log "Upgraded to version: $version"
  log "Backup created before upgrade: $backup"
}

rollback_flow() {
  local target="${1:-}"
  if [[ -z "$target" && -f "$PREVIOUS_VERSION_FILE" ]]; then
    target="$(cat "$PREVIOUS_VERSION_FILE")"
  fi
  if [[ -z "$target" ]]; then
    echo "No rollback target specified and no previous version recorded." >&2
    echo "Available releases:" >&2
    ls -1 "$RELEASES_DIR" >&2 || true
    exit 1
  fi

  stop_services || true
  activate_release "$target"
  start_services

  local latest_backup=""
  latest_backup="$(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -1 || true)"
  if [[ -n "$latest_backup" ]]; then
    printf 'Restore latest data backup too? %s [y/N] ' "$latest_backup"
    local answer
    read -r answer
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
      stop_services || true
      restore_backup "$latest_backup"
      start_services
    fi
  fi

  validate_installation
  log "Rolled back to version: $target"
}

status_flow() {
  echo "install_root=$INSTALL_ROOT"
  echo "data_dir=$DATA_DIR"
  echo "current=$(current_version)"
  echo "releases:"
  ls -1 "$RELEASES_DIR" 2>/dev/null || true
  if [[ -x "$CURRENT_LINK/scripts/manage_service.sh" ]]; then
    (cd "$CURRENT_LINK" && bash scripts/manage_service.sh status dashboard || true)
    (cd "$CURRENT_LINK" && bash scripts/manage_service.sh status vitals_receiver || true)
    (cd "$CURRENT_LINK" && bash scripts/manage_service.sh status daily_pipeline || true)
    (cd "$CURRENT_LINK" && bash scripts/manage_service.sh status weekly_pipeline || true)
  fi
}

command="${1:-}"
shift || true

case "$command" in
  install) install_flow ;;
  upgrade) upgrade_flow ;;
  rollback) rollback_flow "${1:-}" ;;
  backup) backup_data ;;
  status) status_flow ;;
  validate) validate_installation ;;
  -h|--help|"") usage ;;
  *)
    echo "Unknown command: $command" >&2
    usage >&2
    exit 2
    ;;
esac
