#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# openclaw-exporter-to-langfuse one-line uninstaller
#
# Usage:
#   curl -fsSL https://<oss-host>/uninstall.sh | bash
#   curl -fsSL https://<oss-host>/uninstall.sh | bash -s -- -y
#   curl -fsSL https://<oss-host>/uninstall.sh | bash -s -- --install-dir /path/to/exporter
#
# With otelcol-contrib stop:
#   curl -fsSL https://<oss-host>/uninstall.sh | bash -s -- -y --stop-otelcol
#
# OtelCol-only (skip exporter uninstall):
#   curl -fsSL https://<oss-host>/uninstall.sh | bash -s -- -y --skip-plugin --stop-otelcol
# ---------------------------------------------------------------------------
set -euo pipefail

PLUGIN_NAME="openclaw-exporter-to-langfuse"
DIAG_PLUGIN_NAME="diagnostics-otel"
OSS_HOST="ck-langfuse-public.oss-cn-beijing.aliyuncs.com"   # customisable via --oss-host
OSS_BASE_URL="https://${OSS_HOST}/openclaw-exporter-to-langfuse"
SELF_VERSION=""   # set to specific version in versioned copies (e.g. "v0.1.1")
SKIP_CONFIRM=false
INSTALL_DIR=""
ENABLE_PLUGIN_UNINSTALL=true
STOP_OTELCOL=false
SKIP_REDIRECT=false

# ── Color helpers ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }

print_developer_info() {
  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  Developer information${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
  echo "  Agent-lens: ClickHouse or SelectDB plus Langfuse (storage + Langfuse observability)."
  echo "  Agent-lens overview: https://help.aliyun.com/clickhouse/user-guide/agent-lens-overview"
  echo "  ClickHouse: https://help.aliyun.com/clickhouse"
  echo "  SelectDB:   https://help.aliyun.com/selectdb"
  echo ""
}

# Resolve the original user's home when launched via outer sudo.
REAL_HOME="$HOME"
if [[ "$EUID" -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
  SUDO_USER_HOME=$(eval echo "~${SUDO_USER}" 2>/dev/null || true)
  if [[ -n "${SUDO_USER_HOME}" ]] && [[ -d "${SUDO_USER_HOME}" ]]; then
    REAL_HOME="${SUDO_USER_HOME}"
  fi
fi

ensure_root_startup() {
  if [[ "$EUID" -eq 0 ]]; then
    return 0
  fi
  if ! command -v sudo &>/dev/null; then
    error "Root privileges are required and sudo is not available."
    error "Please install sudo and re-run this script with sudo."
    exit 1
  fi
  info "Checking sudo permission (may prompt for password)..."
  if ! sudo -v; then
    error "Failed to acquire sudo privileges."
    error "Please ensure your user has sudo permission, then retry."
    exit 1
  fi
  error "This script must be run as root."
  error "Please re-run with sudo, for example: curl ... | sudo bash -s -- ..."
  exit 1
}

# ── Parse arguments ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)          SKIP_CONFIRM=true;   shift ;;
    --install-dir)
      if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
        error "Option --install-dir requires a value"
        exit 1
      fi
      INSTALL_DIR="$2"; shift 2 ;;
    --skip-plugin)     ENABLE_PLUGIN_UNINSTALL=false; shift ;;
    --stop-otelcol)    STOP_OTELCOL=true; shift ;;
    --skip-redirect)   SKIP_REDIRECT=true; shift ;;
    --oss-host)
      if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
        error "Option --oss-host requires a value"
        exit 1
      fi
      OSS_HOST="$2"; shift 2 ;;
    *)
      error "Unknown option: $1"
      echo ""
      echo "Usage:"
      echo "  uninstall.sh [options]"
      echo ""
      echo "Options:"
      echo "  -y, --yes          Skip confirmation prompt"
      echo "  --install-dir DIR  Specify exporter directory"
      echo "  --skip-plugin      Skip openclaw-exporter-to-langfuse uninstall"
      echo "  --stop-otelcol     Stop otelcol-contrib service (does NOT remove binary or config)"
      exit 1
      ;;
  esac
done

# ── Recompute OSS-derived URL in case --oss-host was provided ──
OSS_BASE_URL="https://${OSS_HOST}/openclaw-exporter-to-langfuse"

print_developer_info

ensure_root_startup

# ── At least one action must be selected ──
if [[ "$ENABLE_PLUGIN_UNINSTALL" == false ]] && [[ "$STOP_OTELCOL" == false ]]; then
  error "Nothing to uninstall. Use --stop-otelcol and/or remove --skip-plugin."
  exit 1
fi

# ── Determine plugin directory ──
if [[ -n "$INSTALL_DIR" ]]; then
  TARGET_DIR="$INSTALL_DIR"
elif [[ -n "${OPENCLAW_STATE_DIR:-}" ]] && [[ -d "${OPENCLAW_STATE_DIR}/extensions/${PLUGIN_NAME}" ]]; then
  TARGET_DIR="${OPENCLAW_STATE_DIR}/extensions/${PLUGIN_NAME}"
elif [[ -d "$REAL_HOME/.openclaw/extensions/${PLUGIN_NAME}" ]]; then
  TARGET_DIR="$REAL_HOME/.openclaw/extensions/${PLUGIN_NAME}"
elif [[ -d "/opt/${PLUGIN_NAME}" ]]; then
  TARGET_DIR="/opt/${PLUGIN_NAME}"
else
  TARGET_DIR=""
fi

# ── Version-redirect: delegate to versioned uninstall.sh when available ──
if [[ "$SKIP_REDIRECT" == false ]] && [[ -z "$SELF_VERSION" ]]; then
  INSTALLED_VERSION=""
  if [[ -n "$TARGET_DIR" ]] && [[ -f "$TARGET_DIR/package.json" ]] && command -v node &>/dev/null; then
    # Read full version from package.json, normalize to 'v' prefix
    # Handles: "0.1.1" -> "v0.1.1", "0.1.1-beta.1" -> "v0.1.1-beta.1", "v0.1.1" -> "v0.1.1"
    INSTALLED_VERSION=$(node -e "
      try {
        const p = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
        const v = (p.version || '').trim();
        process.stdout.write(v ? 'v' + v.replace(/^v/i, '') : '');
      } catch(e) {}
    " "$TARGET_DIR/package.json" 2>/dev/null || true)
  fi
  if [[ -n "$INSTALLED_VERSION" ]]; then
    VERSIONED_UNINSTALL_URL="${OSS_BASE_URL}/${INSTALLED_VERSION}/uninstall.sh"
    VERSIONED_TMP=$(mktemp)
    DOWNLOAD_OK=false
    if command -v curl &>/dev/null && curl -fsSL "$VERSIONED_UNINSTALL_URL" -o "$VERSIONED_TMP" 2>/dev/null; then
      DOWNLOAD_OK=true
    elif command -v wget &>/dev/null && wget -q "$VERSIONED_UNINSTALL_URL" -O "$VERSIONED_TMP" 2>/dev/null; then
      DOWNLOAD_OK=true
    fi
    if [[ "$DOWNLOAD_OK" == true ]]; then
      chmod +x "$VERSIONED_TMP"
      info "Using version-specific uninstall script for exporter ${INSTALLED_VERSION}"
      exec "$VERSIONED_TMP" --skip-redirect "$@"
    else
      warn "Could not download versioned uninstall script for ${INSTALLED_VERSION}; using current script"
      rm -f "$VERSIONED_TMP"
    fi
  fi
fi

# ── Determine openclaw.json path ──
if [[ -n "${OPENCLAW_STATE_DIR:-}" ]] && [[ -f "${OPENCLAW_STATE_DIR}/openclaw.json" ]]; then
  CONFIG_PATH="${OPENCLAW_STATE_DIR}/openclaw.json"
elif [[ -f "$REAL_HOME/.openclaw/openclaw.json" ]]; then
  CONFIG_PATH="$REAL_HOME/.openclaw/openclaw.json"
else
  CONFIG_PATH=""
fi

# ── Summary ──
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  openclaw-exporter-to-langfuse uninstaller${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo ""

if [[ "$ENABLE_PLUGIN_UNINSTALL" == true ]]; then
  if [[ -n "$TARGET_DIR" ]] && [[ -d "$TARGET_DIR" ]]; then
    info "Exporter directory:  ${TARGET_DIR}"
  else
    warn "Exporter directory not found (already removed or custom path)"
  fi
fi

if [[ -n "$CONFIG_PATH" ]]; then
  info "Config file:       ${CONFIG_PATH}"
else
  warn "openclaw.json not found (skipping config cleanup)"
fi

echo ""
echo "  Actions:"
if [[ "$ENABLE_PLUGIN_UNINSTALL" == true ]]; then
  echo -e "    - ${CYAN}Uninstall openclaw-exporter-to-langfuse${NC} (remove files + config)"
fi
if [[ "$STOP_OTELCOL" == true ]]; then
  echo -e "    - ${CYAN}Stop otelcol-contrib service${NC} (config and binary are preserved)"
fi
echo ""

# ── Confirm ──
if [[ "$SKIP_CONFIRM" != true ]]; then
  if [[ -t 0 ]]; then
    read -rp "Proceed with uninstall? [y/N] " answer
  elif [[ -e /dev/tty ]]; then
    read -rp "Proceed with uninstall? [y/N] " answer < /dev/tty
  else
    error "Non-interactive mode detected. Use -y/--yes to skip confirmation."
    exit 1
  fi
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    info "Aborted."
    exit 0
  fi
fi

# ══════════════════════════════════════════════════════
# ── Uninstall openclaw-exporter-to-langfuse ──
# ══════════════════════════════════════════════════════
if [[ "$ENABLE_PLUGIN_UNINSTALL" == true ]]; then

  # ── Clean up openclaw.json ──
  if [[ -n "$CONFIG_PATH" ]] && [[ -f "$CONFIG_PATH" ]]; then
    info "Cleaning up exporter config: ${CONFIG_PATH}"

    if ! command -v node &>/dev/null; then
      warn "Node.js not found, skipping config cleanup. Please edit ${CONFIG_PATH} manually."
    else
      node -e "
const fs = require('fs');
const configPath     = process.argv[1];
const pluginName     = process.argv[2];

let config;
try {
  config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
  process.exit(0);
}

if (!config.plugins) { process.exit(0); }

// ── Remove openclaw-exporter-to-langfuse ──
if (Array.isArray(config.plugins.allow)) {
  config.plugins.allow = config.plugins.allow.filter(n => n !== pluginName);
}
if (config.plugins.load && Array.isArray(config.plugins.load.paths)) {
  config.plugins.load.paths = config.plugins.load.paths.filter(p => !p.includes(pluginName));
}
if (config.plugins.entries && config.plugins.entries[pluginName]) {
  delete config.plugins.entries[pluginName];
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n', 'utf8');
" \
      "$CONFIG_PATH" \
      "$PLUGIN_NAME"

      ok "Exporter config cleaned"
    fi
  fi

  # ── Remove exporter directory ──
  if [[ -n "$TARGET_DIR" ]] && [[ -d "$TARGET_DIR" ]]; then
    # Safety: refuse to delete root-level or system directories
    real_target=$(cd "$TARGET_DIR" && pwd)
    if [[ "$real_target" == "/" ]] || [[ "$real_target" == "/usr" ]] || [[ "$real_target" == "/etc" ]] || [[ "$real_target" == "$REAL_HOME" ]]; then
      error "Refusing to delete unsafe path: ${real_target}"
      exit 1
    fi
    info "Removing ${TARGET_DIR}..."
    rm -rf "$TARGET_DIR"
    ok "Exporter directory removed"
  else
    warn "No exporter directory to remove"
  fi

fi  # end ENABLE_PLUGIN_UNINSTALL

# ══════════════════════════════════════════════════════
# ── Stop otelcol-contrib (optional) ──
# ══════════════════════════════════════════════════════
if [[ "$STOP_OTELCOL" == true ]]; then
  info "Stopping otelcol-contrib service..."

  # Clean up diagnostics-otel config from openclaw.json
  if [[ -n "$CONFIG_PATH" ]] && [[ -f "$CONFIG_PATH" ]]; then
    if command -v node &>/dev/null; then
      info "Disabling diagnostics-otel in config..."
      node -e "
const fs = require('fs');
const configPath     = process.argv[1];
const diagPluginName = process.argv[2];

let config;
try {
  config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
  process.exit(0);
}

// Disable diagnostics-otel in plugins.entries (keep entry, just disable)
if (config.plugins && config.plugins.entries && config.plugins.entries[diagPluginName]) {
  config.plugins.entries[diagPluginName].enabled = false;
}

// Disable diagnostics.otel (keep config for easy re-enable)
if (config.diagnostics && config.diagnostics.otel) {
  config.diagnostics.otel.enabled = false;
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n', 'utf8');
" \
      "$CONFIG_PATH" \
      "$DIAG_PLUGIN_NAME"

      ok "diagnostics-otel disabled in config"
    fi
  fi

  # Stop the service (do NOT remove binary or config)
  OTELCOL_STOPPED=false
  if command -v systemctl &>/dev/null; then
    if systemctl is-active --quiet otelcol-contrib 2>/dev/null; then
      if systemctl stop otelcol-contrib 2>&1; then
        ok "otelcol-contrib service stopped (systemctl)"
        OTELCOL_STOPPED=true
      else
        warn "Failed to stop otelcol-contrib via systemctl"
      fi
    else
      ok "otelcol-contrib service is not running"
      OTELCOL_STOPPED=true
    fi
  elif command -v service &>/dev/null; then
    if service otelcol-contrib stop 2>&1; then
      ok "otelcol-contrib service stopped (service)"
      OTELCOL_STOPPED=true
    else
      warn "Failed to stop otelcol-contrib via service command"
    fi
  elif pgrep -x otelcol-contrib &>/dev/null; then
    warn "No systemctl/service found. otelcol-contrib process is running."
    warn "Please stop it manually: kill \$(pgrep -x otelcol-contrib)"
  else
    ok "otelcol-contrib is not running"
    OTELCOL_STOPPED=true
  fi

  if [[ "$OTELCOL_STOPPED" == true ]]; then
    info "Note: otelcol-contrib binary and config (/etc/otelcol-contrib/) are preserved."
    info "To fully remove, use your package manager (e.g., yum remove otelcol-contrib)."
  fi

fi  # end STOP_OTELCOL

# ── Restart gateway ──
OPENCLAW_CMD="openclaw"
if command -v "$OPENCLAW_CMD" &>/dev/null; then
  restart_gateway() {
    local restart_output=""
    local user_restart_cmd=""

    if [[ "$EUID" -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]] && command -v sudo &>/dev/null; then
      user_restart_cmd="sudo -iu ${SUDO_USER} ${OPENCLAW_CMD} gateway restart"
      if restart_output=$(sudo -iu "$SUDO_USER" "$OPENCLAW_CMD" gateway restart 2>&1); then
        ok "Gateway restarted (as ${SUDO_USER})"
        return 0
      fi
    fi

    if restart_output=$("$OPENCLAW_CMD" gateway restart 2>&1); then
      ok "Gateway restarted"
      return 0
    fi

    warn "Gateway restart failed. Run manually: openclaw gateway restart"
    if [[ -n "$user_restart_cmd" ]]; then
      warn "Or run as service user: ${user_restart_cmd}"
    fi
    if [[ "$restart_output" == *"Cannot access user instance remotely"* ]]; then
      warn "Detected user-systemd access issue; run the command in an interactive shell."
    fi
    return 1
  }

  info "Restarting OpenClaw gateway..."
  restart_gateway || true
else
  warn "OpenClaw CLI not found, skipping gateway restart."
fi

# ── Done ──
echo ""
print_developer_info
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ Uninstall completed successfully!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
if [[ "$ENABLE_PLUGIN_UNINSTALL" == true ]]; then
  echo -e "  openclaw-exporter-to-langfuse:  ${GREEN}removed${NC}"
fi
if [[ "$STOP_OTELCOL" == true ]]; then
  echo -e "  otelcol-contrib:           ${GREEN}stopped${NC} (binary & config preserved)"
fi
echo ""
