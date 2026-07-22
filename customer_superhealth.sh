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
DEPLOYMENT_MODE="${SUPERHEALTH_DEPLOYMENT_MODE:-multi}"
INSTALL_ROOT="${SUPERHEALTH_INSTALL_ROOT:-$HOME/superHealth}"
DATA_DIR="${SUPERHEALTH_DATA_DIR:-$HOME/.superhealth}"
DEPLOY_KEY_PATH="${SUPERHEALTH_DEPLOY_KEY_PATH:-$HOME/.ssh/superhealth-deploy}"
DASHBOARD_PORT="${DASHBOARD_PORT:-8501}"
VITALS_PORT="${SUPERHEALTH_VITALS_PORT:-8506}"
INSTALLER_URL="${SUPERHEALTH_INSTALLER_URL:-}"
COMMAND_PATH="${SUPERHEALTH_COMMAND_PATH:-$HOME/.local/bin/superhealth}"
SCRIPT_PATH="${SUPERHEALTH_SCRIPT_PATH:-${BASH_SOURCE[0]}}"
CONFIG_FILE="${SUPERHEALTH_INSTALLER_CONFIG:-$DATA_DIR/installer.env}"
DASHBOARD_SETUP_GUIDE_URL="${SUPERHEALTH_DASHBOARD_SETUP_GUIDE_URL:-https://cdn.jsdelivr.net/gh/zj05409/superhealth-installer@71a9cce113bd0a700a6d21cc18f828af921234a4/dashboard-setup.md}"

SOURCE_DIR="$INSTALL_ROOT/source"
RELEASES_DIR="$INSTALL_ROOT/releases"
CURRENT_LINK="$INSTALL_ROOT/current"
PREVIOUS_VERSION_FILE="$INSTALL_ROOT/.previous_version"
BACKUP_DIR="$DATA_DIR/backups"
INSTALL_LOG="$DATA_DIR/install.log"
SUDO=(sudo)
CURRENT_STAGE=""

log() {
  printf '\n[superhealth] %s\n' "$*" >&2
}

add_user_tool_paths() {
  # systemd user services do not inherit an interactive shell's nvm/pnpm PATH.
  # Discover standard per-user locations so an existing OpenClaw install works
  # during unattended installation as well as from an SSH terminal.
  local dir
  for dir in \
    "$HOME/.local/bin" \
    "$HOME/.local/share/pnpm/bin" \
    "$HOME/.local/share/pnpm" \
    "$HOME/.npm-global/bin" \
    "$HOME/.nvm/current/bin" \
    "$HOME"/.nvm/versions/node/*/bin; do
    [[ -d "$dir" ]] && PATH="$dir:$PATH"
  done
  export PATH
}

validate_runtime_prerequisites() {
  add_user_tool_paths
  if [[ "$DEPLOYMENT_MODE" == "multi" ]]; then
    command -v openclaw >/dev/null 2>&1 || {
      echo "OpenClaw is required for multi-user mode. Complete the administrator's OpenClaw binding first." >&2
      return 1
    }
    command -v node >/dev/null 2>&1 || {
      echo "Node.js is required to run OpenClaw, but it was not found in the unattended installer PATH." >&2
      return 1
    }
  fi
}

usage() {
  cat <<EOF
Usage: bash customer_superhealth.sh <command> [options]

Commands:
  install       First install: system packages, deploy key, clone, start services, validate.
  upgrade       Pull latest code, backup data, deploy new release, validate, auto-rollback on failure.
  rollback      Switch back to the previous release. Prompts before restoring latest data backup.
  backup        Create a local backup of SuperHealth data/config.
  status        Show release and service status.
  validate      Verify layout, Python imports, services, and HTTP health endpoints.
  migrate-multiuser  Explicitly migrate a legacy single-user deployment.

Options for install/upgrade:
  --branch NAME        Git branch to install or upgrade to.
  --mode single|multi  Deployment mode. Existing installs default to their saved mode.

Environment:
  SUPERHEALTH_BRANCH             Git branch to deploy. Default: $BRANCH
  SUPERHEALTH_DEPLOYMENT_MODE    single or multi. Default: $DEPLOYMENT_MODE
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
    write_config_line SUPERHEALTH_DEPLOYMENT_MODE "$DEPLOYMENT_MODE"
    write_config_line SUPERHEALTH_INSTALL_ROOT "$INSTALL_ROOT"
    write_config_line SUPERHEALTH_DATA_DIR "$DATA_DIR"
    write_config_line SUPERHEALTH_DEPLOY_KEY_PATH "$DEPLOY_KEY_PATH"
    write_config_line DASHBOARD_PORT "$DASHBOARD_PORT"
    write_config_line SUPERHEALTH_VITALS_PORT "$VITALS_PORT"
    write_config_line SUPERHEALTH_INSTALLER_URL "$INSTALLER_URL"
    write_config_line SUPERHEALTH_ACTIVATION_TOKEN "${SUPERHEALTH_ACTIVATION_TOKEN:-}"
    write_config_line SUPERHEALTH_MACHINE_FINGERPRINT "${SUPERHEALTH_MACHINE_FINGERPRINT:-}"
    write_config_line SUPERHEALTH_INSTALL_EVENT_URL "${SUPERHEALTH_INSTALL_EVENT_URL:-}"
  } >"$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

report_install_event() {
  local stage="$1" status="$2" error="${3:-}"
  local event_url="${SUPERHEALTH_INSTALL_EVENT_URL:-}"
  local fingerprint="${SUPERHEALTH_MACHINE_FINGERPRINT:-}"
  [[ -n "$event_url" && -n "$fingerprint" ]] || return 0

  local log_tail=""
  if [[ -f "$INSTALL_LOG" ]]; then
    log_tail="$(tail -n 80 "$INSTALL_LOG" | sed -E 's/(SUPERHEALTH_DEPLOY_KEY_B64=)[^[:space:]]+/\1[redacted]/g; s#(/key/[^ ?]+)#/key/[redacted]#g')"
  fi

  curl -fsS --connect-timeout 5 --max-time 15 \
    --data-urlencode "machine_fingerprint=$fingerprint" \
    --data-urlencode "stage=$stage" \
    --data-urlencode "status=$status" \
    --data-urlencode "error=$error" \
    --data-urlencode "log=$log_tail" \
    "$event_url" >/dev/null 2>&1 || true
}

run_stage() {
  local stage="$1"
  shift
  CURRENT_STAGE="$stage"
  report_install_event "$stage" "running"
  "$@"
  report_install_event "$stage" "ok"
}

report_install_failure() {
  local exit_code="$?"
  if [[ "$exit_code" != "0" && -n "$CURRENT_STAGE" ]]; then
    report_install_event "$CURRENT_STAGE" "failed" "exit code $exit_code"
  fi
  exit "$exit_code"
}

start_install_logging() {
  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  touch "$INSTALL_LOG"
  chmod 600 "$INSTALL_LOG"
  exec > >(tee -a "$INSTALL_LOG") 2>&1
  printf '\n[superhealth] ===== automatic install attempt %s =====\n' "$(date -Iseconds)"
}

install_local_command() {
  persist_installer_config
  mkdir -p "$(dirname "$COMMAND_PATH")"
  if [[ ! -f "$SCRIPT_PATH" ]]; then
    echo "Cannot install local command because script path is not a file: $SCRIPT_PATH" >&2
    return
  fi
  if [[ ! -e "$COMMAND_PATH" || ! "$SCRIPT_PATH" -ef "$COMMAND_PATH" ]]; then
    cp "$SCRIPT_PATH" "$COMMAND_PATH"
  fi
  chmod +x "$COMMAND_PATH"
  log "Installed local command: $COMMAND_PATH"

  case ":$PATH:" in
    *":$(dirname "$COMMAND_PATH"):"*) ;;
    *) echo "Tip: add $(dirname "$COMMAND_PATH") to PATH, or run $COMMAND_PATH directly." >&2 ;;
  esac
}

configure_channel_from_local_messaging() {
  if [[ -f "$DATA_DIR/control.db" ]]; then
    log "Multi-user channel bindings are managed per user; skipping legacy global channel auto-config"
    return
  fi
  if [[ "${SUPERHEALTH_DISABLE_CHANNEL_AUTOCONFIG:-0}" == "1" ]]; then
    return
  fi

  log "Auto-configuring local messaging channel"
  python3 - <<'PY'
import json
from pathlib import Path

home = Path.home()
config_path = home / ".superhealth" / "config.toml"


def load_json(path: Path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def discover_hermes():
    accounts_dir = home / ".hermes" / "weixin" / "accounts"
    accounts_index = home / ".hermes" / "weixin" / "accounts.json"
    candidates = []
    context_token_files = []
    index = load_json(accounts_index)
    if isinstance(index, list):
        candidates.extend(str(item) for item in index)
    if accounts_dir.exists():
        files = sorted(
            accounts_dir.glob("*-im-bot.json"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        candidates.extend(path.stem for path in files)
        context_token_files = sorted(
            accounts_dir.glob("*.context-tokens.json"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )

    seen = set()
    for account_id in candidates:
        if account_id in seen:
            continue
        seen.add(account_id)
        account_file = accounts_dir / f"{account_id}.json"
        data = load_json(account_file)
        if not isinstance(data, dict):
            continue
        target = str(data.get("userId") or data.get("target") or "").strip()
        if account_id and target:
            return account_id, target, "hermes"

    context_suffix = ".context-tokens.json"
    for context_file in context_token_files:
        account_id = context_file.name[:-len(context_suffix)] if context_file.name.endswith(context_suffix) else ""
        data = load_json(context_file)
        targets = []
        if isinstance(data, dict):
            targets.extend(str(key) for key in data.keys())
        elif isinstance(data, list):
            targets.extend(str(item) for item in data)
        for target in targets:
            target = target.strip()
            if account_id and target:
                return account_id, target, "hermes"
    return "", "", ""


def discover_openclaw():
    accounts_dir = home / ".openclaw" / "openclaw-weixin" / "accounts"
    accounts_index = home / ".openclaw" / "openclaw-weixin" / "accounts.json"
    candidates = []
    index = load_json(accounts_index)
    if isinstance(index, dict):
        candidates.extend(str(key) for key in index.keys())
    elif isinstance(index, list):
        candidates.extend(str(item) for item in index)
    if accounts_dir.exists():
        files = sorted(
            accounts_dir.glob("*.json"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        candidates.extend(path.stem for path in files)

    seen = set()
    for account_id in candidates:
        if account_id in seen:
            continue
        seen.add(account_id)
        account_file = accounts_dir / f"{account_id}.json"
        data = load_json(account_file)
        if not isinstance(data, dict):
            continue
        target = str(data.get("userId") or data.get("target") or "").strip()
        if account_id and target:
            return account_id, target, "openclaw"
    return "", "", ""


def replace_or_append(section: list[str], key: str, value: str) -> list[str]:
    rendered = json.dumps(value, ensure_ascii=False)
    prefix = f"{key} "
    out = []
    replaced = False
    for line in section:
        stripped = line.strip()
        if stripped.startswith(prefix) or stripped.startswith(f"{key}="):
            out.append(f"{key} = {rendered}")
            replaced = True
        else:
            out.append(line)
    if not replaced:
        out.append(f"{key} = {rendered}")
    return out


def upsert_channel(account_id: str, target: str, source: str) -> None:
    config_path.parent.mkdir(parents=True, exist_ok=True)
    lines = config_path.read_text().splitlines() if config_path.exists() else []

    sections: list[tuple[str, list[str]]] = []
    current_name = ""
    current_lines: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            sections.append((current_name, current_lines))
            current_name = stripped.strip("[]")
            current_lines = [line]
        else:
            current_lines.append(line)
    sections.append((current_name, current_lines))

    found = False
    next_sections = []
    for name, section_lines in sections:
        if name == "channel":
            found = True
            body = section_lines[1:] if section_lines and section_lines[0].strip() == "[channel]" else section_lines
            body = replace_or_append(body, "type", "wechat")
            body = replace_or_append(body, "backend", source)
            body = replace_or_append(body, "account_id", account_id)
            body = replace_or_append(body, "target", target)
            next_sections.append((name, ["[channel]"] + body))
        else:
            next_sections.append((name, section_lines))

    if not found:
        if next_sections and next_sections[-1][1] and next_sections[-1][1][-1] != "":
            next_sections[-1][1].append("")
        next_sections.append(
            (
                "channel",
                [
                    "[channel]",
                    'type = "wechat"',
                    f"backend = {json.dumps(source, ensure_ascii=False)}",
                    f"account_id = {json.dumps(account_id, ensure_ascii=False)}",
                    f"target = {json.dumps(target, ensure_ascii=False)}",
                ],
            )
        )

    rendered_lines: list[str] = []
    for _name, section_lines in next_sections:
        rendered_lines.extend(section_lines)
    config_path.write_text("\n".join(rendered_lines).rstrip() + "\n")
    config_path.chmod(0o600)
    print(f"[superhealth] Channel auto-configured from {source}: account_id={account_id} target={target}")


account_id, target, source = discover_hermes()
if not account_id:
    account_id, target, source = discover_openclaw()
if not account_id:
    print("[superhealth] No Hermes/OpenClaw local messaging account found; channel config unchanged.")
else:
    upsert_channel(account_id, target, source)
PY
}

provision_multiuser_openclaw() {
  local install_mode="${1:-install}"

  if [[ "$DEPLOYMENT_MODE" == "single" ]]; then
    echo "Single-user mode was removed in v12; the runtime registry is control.db." >&2
    echo "Re-run with DEPLOYMENT_MODE=multi." >&2
    return 1
  fi

  # main → v12 upgrades are always migrated: the runtime registry is control.db
  # and the legacy single-user layout no longer boots. Fresh installs and
  # already-migrated installs continue through the provisioning path below.

  log "Provisioning admin-only multi-user mode and the agent-bound OpenClaw plugin"
  add_user_tool_paths
  command -v openclaw >/dev/null 2>&1 || {
    echo "OpenClaw is required. Configure WeCom and send one administrator message before installing SuperHealth." >&2
    return 1
  }
  openclaw config set channels.wecom.dmPolicy open
  openclaw config set channels.wecom.allowFrom '["*"]'

  if [[ ! -x "$CURRENT_LINK/venv/bin/python3" ]]; then
    python3 -m venv "$CURRENT_LINK/venv"
  fi
  "$CURRENT_LINK/venv/bin/python3" -m pip install -U pip
  "$CURRENT_LINK/venv/bin/python3" -m pip install -e "$CURRENT_LINK"
  if [[ "$install_mode" == "upgrade" && ! -f "$DATA_DIR/control.db" ]]; then
    log "Legacy main-branch installation detected; running forced v12 migration"
    backup_data >/dev/null
    if ! "$CURRENT_LINK/venv/bin/python3" "$CURRENT_LINK/scripts/migrate_to_multiuser.py"; then
      echo "Forced migration failed; restore the backup and retry." >&2
      return 1
    fi
    DEPLOYMENT_MODE="multi"
    persist_installer_config
  elif [[ -f "$DATA_DIR/control.db" ]]; then
    log "Existing multi-user registry detected; keeping all users unchanged"
  fi
  "$CURRENT_LINK/venv/bin/python3" "$CURRENT_LINK/scripts/bootstrap_multiuser.py"

  # OpenClaw 2026.6+ rejects --force together with --link. Remove only the
  # persisted registration first, then recreate the link to the active release.
  if openclaw plugins inspect superhealth --json >/dev/null 2>&1; then
    openclaw plugins uninstall --force --keep-files superhealth
  fi
  openclaw plugins install --link "$CURRENT_LINK/openclaw-plugin"
  openclaw plugins enable superhealth
  if [[ -f "$HOME/.openclaw/plugin-skills/superhealth-nutrition/SKILL.md" ]]; then
    chmod 600 "$HOME/.openclaw/plugin-skills/superhealth-nutrition/SKILL.md"
    mv "$HOME/.openclaw/plugin-skills/superhealth-nutrition/SKILL.md" \
      "$HOME/.openclaw/plugin-skills/superhealth-nutrition/SKILL.md.disabled"
  fi
  openclaw gateway restart --force
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
    SUDO=(sudo -n)
    return
  fi
  if [[ -t 0 ]]; then
    sudo -v
    SUDO=(sudo)
    return
  fi
  echo "sudo requires a password, but this installer is not running in an interactive terminal." >&2
  echo "Run the install command directly in the server terminal, or configure passwordless sudo for this user." >&2
  exit 1
}

install_system_dependencies() {
  log "Installing Ubuntu system dependencies"
  "${SUDO[@]}" apt-get update

  local packages=(
    git curl wget ca-certificates openssh-client jq sqlite3 tar gzip unzip \
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

  "${SUDO[@]}" DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

enable_user_linger() {
  if command -v loginctl >/dev/null 2>&1; then
    log "Enabling user service persistence"
    "${SUDO[@]}" loginctl enable-linger "$(id -un)" || true
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
  touch "$HOME/.ssh/known_hosts"
  chmod 644 "$HOME/.ssh/known_hosts"
  if ! ssh-keygen -F "[ssh.github.com]:443" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
    ssh-keyscan -p 443 ssh.github.com >>"$HOME/.ssh/known_hosts" 2>/dev/null
  fi
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
  DASHBOARD_PORT="$DASHBOARD_PORT" SUPERHEALTH_INSTALL_PLAYWRIGHT=0 bash scripts/manage_service.sh start dashboard
  install_playwright_chromium_fast
  SUPERHEALTH_VITALS_PORT="$VITALS_PORT" SUPERHEALTH_INSTALL_PLAYWRIGHT=0 bash scripts/manage_service.sh start vitals_receiver
  SUPERHEALTH_INSTALL_PLAYWRIGHT=0 bash scripts/manage_service.sh schedule daily_pipeline 7 0
  SUPERHEALTH_INSTALL_PLAYWRIGHT=0 bash scripts/manage_service.sh schedule weekly_pipeline 20 30 0
}

install_playwright_chromium_fast() {
  local python_bin="$CURRENT_LINK/venv/bin/python3"
  if [[ ! -x "$python_bin" ]]; then
    echo "Playwright browser install skipped: venv python not found yet." >&2
    return
  fi
  if ! "$python_bin" -c "import playwright" >/dev/null 2>&1; then
    echo "Playwright browser install skipped: playwright package not installed." >&2
    return
  fi

  playwright_chromium_usable "$python_bin" && {
    log "Playwright Chromium is already usable"
    return
  }

  if ! install_playwright_chromium_from_npmmirror "$python_bin"; then
    log "Fast Chromium install failed; falling back to Playwright installer"
    "$python_bin" -m playwright install chromium
  fi

  playwright_chromium_usable "$python_bin"
}

playwright_chromium_usable() {
  local python_bin="$1"
  "$python_bin" - <<'PY' >/dev/null 2>&1
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    browser.close()
PY
}

install_playwright_chromium_from_npmmirror() {
  local python_bin="$1"
  local browser_lines name revision browser_version target_dir marker executable archive_name archive_dir download_url tmp_dir zip_path
  browser_lines="$("$python_bin" - <<'PY'
import json
from pathlib import Path
import playwright

root = Path(playwright.__file__).resolve().parent
data = json.loads((root / "driver" / "package" / "browsers.json").read_text())
wanted = {"chromium", "chromium-headless-shell"}
for browser in data["browsers"]:
    if browser["name"] in wanted:
        print(f"{browser['name']}\t{browser['revision']}\t{browser['browserVersion']}")
PY
)"

  if [[ -z "$browser_lines" ]]; then
    echo "Could not find Chromium descriptors in Playwright browsers.json" >&2
    return 1
  fi

  while IFS=$'\t' read -r name revision browser_version; do
    [[ -n "$name" && -n "$revision" && -n "$browser_version" ]] || continue
    case "$name" in
      chromium)
        target_dir="$HOME/.cache/ms-playwright/chromium-$revision"
        archive_name="chrome-linux64.zip"
        archive_dir="chrome-linux64"
        executable="$target_dir/$archive_dir/chrome"
        download_url="${SUPERHEALTH_PLAYWRIGHT_CHROMIUM_URL:-https://cdn.npmmirror.com/binaries/chrome-for-testing/${browser_version}/linux64/${archive_name}}"
        ;;
      chromium-headless-shell)
        target_dir="$HOME/.cache/ms-playwright/chromium_headless_shell-$revision"
        archive_name="chrome-headless-shell-linux64.zip"
        archive_dir="chrome-headless-shell-linux64"
        executable="$target_dir/$archive_dir/chrome-headless-shell"
        download_url="${SUPERHEALTH_PLAYWRIGHT_HEADLESS_SHELL_URL:-https://cdn.npmmirror.com/binaries/chrome-for-testing/${browser_version}/linux64/${archive_name}}"
        ;;
      *)
        continue
        ;;
    esac

    marker="$target_dir/INSTALLATION_COMPLETE"
    if [[ -x "$executable" && -f "$marker" ]]; then
      log "Playwright $name already installed: $target_dir"
      continue
    fi

    tmp_dir="$(mktemp -d)"
    zip_path="$tmp_dir/$archive_name"
    log "Installing Playwright $name from $download_url"
    if ! curl -fL --retry 3 --retry-delay 2 "$download_url" -o "$zip_path"; then
      rm -rf "$tmp_dir"
      return 1
    fi
    rm -rf "$target_dir"
    mkdir -p "$target_dir"
    unzip -q "$zip_path" -d "$target_dir"
    rm -rf "$tmp_dir"
    chmod +x "$executable"
    touch "$target_dir/DEPENDENCIES_VALIDATED" "$marker"
  done <<<"$browser_lines"
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
  if [[ "$DEPLOYMENT_MODE" == "multi" ]]; then
    test -f "$DATA_DIR/control.db"
    [[ "$(stat -c '%a' "$DATA_DIR/control.db")" == "600" ]]
    CONTROL_DB_PATH="$DATA_DIR/control.db" venv/bin/python3 - <<'PY'
import os

from superhealth.multiuser import control_db, registry

conn = control_db.connect(os.environ["CONTROL_DB_PATH"])
try:
    users = registry.list_users(conn)
    admins = [u for u in users if u.role == "admin" and u.status == "active"]
    regulars = [u for u in users if u.role == "user" and u.status == "active"]
    assert len(admins) == 1, f"expected exactly one active administrator, found {len(admins)}"
    assert regulars, "expected at least one active regular user"
    agent_ids = [u.agent_id for u in users]
    assert len(agent_ids) == len(set(agent_ids)), "an OpenClaw agent is bound to multiple users"
    for user in [*admins, *regulars]:
        expected_use = "ops" if user.role == "admin" else "health"
        rows = conn.execute(
            "SELECT key_use FROM agent_keys WHERE agent_id=? AND status='active'",
            (user.agent_id,),
        ).fetchall()
        assert [r["key_use"] for r in rows] == [expected_use], (
            f"key invariant failed for {user.agent_id}"
        )
finally:
    conn.close()
PY
    if [[ "${SUPERHEALTH_SKIP_OPENCLAW_VALIDATION:-0}" != "1" ]]; then
      CONTROL_DB_PATH="$DATA_DIR/control.db" venv/bin/python3 -c "
import os
from superhealth.multiuser import control_db, registry
conn = control_db.connect(os.environ['CONTROL_DB_PATH'])
try:
    admin = next(u for u in registry.list_users(conn) if u.role == 'admin' and u.status == 'active')
    assert admin.agent_id == 'superhealth-admin'
finally:
    conn.close()
"
      add_user_tool_paths
      systemctl --user is-active openclaw-gateway.service >/dev/null
      openclaw plugins inspect superhealth --runtime --json | grep -q 'superhealth_chat'
    fi
  else
    echo "Single-user mode was removed in v12; DEPLOYMENT_MODE must be multi." >&2
    return 1
  fi
  playwright_chromium_usable "$CURRENT_LINK/venv/bin/python3"
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

install_telemetry_timer() {
  log "Installing telemetry reporter"
  local script_src
  script_src="${BASH_SOURCE[0]%/*}/telemetry_report.sh"
  if [[ ! -f "$script_src" ]]; then
    script_src="$(dirname "${SCRIPT_PATH:-$0}")/telemetry_report.sh"
  fi
  if [[ ! -f "$script_src" ]]; then
    echo "telemetry_report.sh not found" >&2
    return 1
  fi

  local script_dest="$HOME/.local/bin/telemetry_report.sh"
  mkdir -p "$HOME/.local/bin" "$DATA_DIR/logs"
  if [[ ! "$script_src" -ef "$script_dest" ]]; then
    cp "$script_src" "$script_dest"
  fi
  chmod +x "$script_dest"

  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/superhealth-telemetry.service" <<UNIT
[Unit]
Description=SuperHealth telemetry reporter
After=network-online.target

[Service]
Type=oneshot
ExecStart=$HOME/.local/bin/telemetry_report.sh
WorkingDirectory=$HOME
StandardOutput=append:$DATA_DIR/logs/telemetry.log
StandardError=append:$DATA_DIR/logs/telemetry.log

[Install]
WantedBy=default.target
UNIT

  cat > "$HOME/.config/systemd/user/superhealth-telemetry.timer" <<UNIT
[Unit]
Description=Run SuperHealth telemetry reporter daily

[Timer]
OnCalendar=*-*-* 08:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
UNIT

  systemctl --user daemon-reload
  systemctl --user enable --now superhealth-telemetry.timer
  log "Telemetry timer installed (daily at 08:00)"
}

install_flow() {
  start_install_logging
  trap report_install_failure EXIT
  run_stage preflight require_ubuntu
  run_stage runtime_preflight validate_runtime_prerequisites
  run_stage sudo require_sudo
  run_stage system_dependencies install_system_dependencies
  run_stage user_linger enable_user_linger
  run_stage pip_mirror configure_pip_mirror
  run_stage fetch_deploy_key read_deploy_key
  run_stage ssh_alias configure_ssh_alias
  run_stage local_command install_local_command
  run_stage telemetry_timer install_telemetry_timer
  run_stage sync_source sync_source_repo
  local version
  CURRENT_STAGE="build_release"
  report_install_event "$CURRENT_STAGE" "running"
  version="$(build_release_from_source)"
  report_install_event "$CURRENT_STAGE" "ok"
  run_stage stop_services stop_services
  run_stage activate_release activate_release "$version"
  run_stage provision_multiuser provision_multiuser_openclaw install
  run_stage configure_channel configure_channel_from_local_messaging
  run_stage start_services start_services
  run_stage validate validate_installation
  CURRENT_STAGE="completed"
  report_install_event completed completed
  trap - EXIT
  log "Installed version: $version"
  log "DeepSeek top up: https://platform.deepseek.com/top_up"
  log "DeepSeek API keys: https://platform.deepseek.com/api_keys"
  log "Baichuan top up: https://platform.baichuan-ai.com/console/recharge"
  log "Baichuan API keys: https://platform.baichuan-ai.com/console/apikey"
  log "Dashboard setup guide: $DASHBOARD_SETUP_GUIDE_URL"
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
  install_telemetry_timer

  local previous backup version
  previous="$(current_version)"
  [[ -n "$previous" ]] && printf '%s\n' "$previous" >"$PREVIOUS_VERSION_FILE"
  backup="$(backup_data)"

  sync_source_repo
  version="$(build_release_from_source)"

  if ! (
    stop_services
    activate_release "$version"
    provision_multiuser_openclaw upgrade
    configure_channel_from_local_messaging
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

migrate_multiuser_flow() {
  local skip_openclaw=0 arg
  if [[ "$DEPLOYMENT_MODE" == "multi" && -f "$DATA_DIR/control.db" ]]; then
    log "Deployment is already in multi-user mode"
    return 0
  fi
  if [[ ! -x "$CURRENT_LINK/venv/bin/python3" ]]; then
    echo "SuperHealth is not installed; install or upgrade before migration." >&2
    return 1
  fi

  # --skip-openclaw is an installer-level flag; the v12 migration CLI only
  # accepts --admin-username/--primary-username/--candidate-session-key/--workspace.
  local forward_args=()
  for arg in "$@"; do
    case "$arg" in
      --skip-openclaw) skip_openclaw=1 ;;
      *) forward_args+=("$arg") ;;
    esac
  done

  backup_data >/dev/null
  stop_services
  if ! "$CURRENT_LINK/venv/bin/python3" "$CURRENT_LINK/scripts/migrate_to_multiuser.py" "${forward_args[@]}"; then
    start_services || true
    return 1
  fi
  DEPLOYMENT_MODE="multi"
  persist_installer_config
  if [[ "$skip_openclaw" == "0" ]]; then
    if ! provision_multiuser_openclaw upgrade; then
      start_services || true
      return 1
    fi
  else
    log "OpenClaw provisioning skipped for this migration test"
  fi
  start_services
  if [[ "$skip_openclaw" == "1" ]]; then
    SUPERHEALTH_SKIP_OPENCLAW_VALIDATION=1 validate_installation
  else
    validate_installation
  fi
  log "Migration completed; deployment mode is now multi"
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
  echo "branch=$BRANCH"
  echo "deployment_mode=$DEPLOYMENT_MODE"
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

remaining_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      [[ $# -ge 2 ]] || { echo "--branch requires a value" >&2; exit 2; }
      BRANCH="$2"
      shift 2
      ;;
    --branch=*)
      BRANCH="${1#*=}"
      shift
      ;;
    --mode)
      [[ $# -ge 2 ]] || { echo "--mode requires single or multi" >&2; exit 2; }
      DEPLOYMENT_MODE="$2"
      shift 2
      ;;
    --mode=*)
      DEPLOYMENT_MODE="${1#*=}"
      shift
      ;;
    *)
      remaining_args+=("$1")
      shift
      ;;
  esac
done

if [[ ! "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ || "$BRANCH" == -* || "$BRANCH" == *..* ]]; then
  echo "Invalid Git branch: $BRANCH" >&2
  exit 2
fi
if [[ "$DEPLOYMENT_MODE" != "single" && "$DEPLOYMENT_MODE" != "multi" ]]; then
  echo "Invalid deployment mode: $DEPLOYMENT_MODE (expected single or multi)" >&2
  exit 2
fi

case "$command" in
  install) install_flow ;;
  upgrade) upgrade_flow ;;
  rollback) rollback_flow "${remaining_args[0]:-}" ;;
  backup) backup_data ;;
  status) status_flow ;;
  validate) validate_installation ;;
  migrate-multiuser) migrate_multiuser_flow "${remaining_args[@]}" ;;
  -h|--help|"") usage ;;
  *)
    echo "Unknown command: $command" >&2
    usage >&2
    exit 2
    ;;
esac
