#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# openclaw-exporter-to-langfuse one-line installer
#
# Usage (with pk/sk - recommended):
#   curl -fsSL https://<oss-host>/install.sh | bash -s -- \
#     --endpoint "https://..." \
#     --pk "pk-lf-xxx" \
#     --sk "sk-lf-yyy" \
#     --serviceName "my-service" \
#     --tags "id:openclaw,ip:127.0.0.1" \
#     --user-id "user_12345" \
#     --skill-tagging-enabled \
#     --skills-roots "/opt/git/openclaw/skills/custom/skills"
#
# Usage (with authorization):
#   curl -fsSL https://<oss-host>/install.sh | bash -s -- \
#     --endpoint "https://..." \
#     --authorization "Basic xxx" \
#     --serviceName "my-service" \
#     --tags "[\"id:openclaw\",\"ip:127.0.0.1\"]"
#
# With OtelCol-Contrib + ClickHouse (optional):
#   curl -fsSL https://<oss-host>/install.sh | bash -s -- \
#     --endpoint "https://..." \
#     --pk "pk-lf-xxx" --sk "sk-lf-yyy" \
#     --serviceName "my-service" \
#     --enable-otelcol \
#     --ck-endpoint "http://<ck-host>:8123" \
#     --ck-username "default" \
#     --ck-password "password"
#
# OtelCol-only (skip Langfuse exporter):
#   curl -fsSL https://<oss-host>/install.sh | bash -s -- \
#     --serviceName "my-service" \
#     --skip-plugin \
#     --enable-otelcol \
#     --ck-endpoint "http://<ck-host>:8123" \
#     --ck-username "default" \
#     --ck-password "password"
# ---------------------------------------------------------------------------
set -euo pipefail

PLUGIN_NAME="openclaw-exporter-to-langfuse"
# ── Plugin version — baked in by pack.sh for versioned releases (e.g., "v0.1.2"); empty = latest (floating) ──
PLUGIN_VERSION=""
# ── OSS host — full hostname, customisable via --oss-host (e.g. my-bucket.oss-cn-beijing.aliyuncs.com) ──
OSS_HOST="ck-langfuse-public.oss-cn-beijing.aliyuncs.com"
# ── OSS base URL (versioned assets live under <OSS_BASE_URL>/v<version>/) ──
OSS_BASE_URL="https://${OSS_HOST}/openclaw-exporter-to-langfuse"
if [[ -n "$PLUGIN_VERSION" ]]; then
  DEFAULT_PLUGIN_URL="${OSS_BASE_URL}/${PLUGIN_VERSION}/openclaw-exporter-to-langfuse.tar.gz"
else
  DEFAULT_PLUGIN_URL="${OSS_BASE_URL}/openclaw-exporter-to-langfuse.tar.gz"
fi

DIAG_PLUGIN_NAME="diagnostics-otel"
OTELCOL_VERSION="0.136.0"
OTELCOL_OSS_BASE="https://${OSS_HOST}/opentelemetry-collector-releases"
OTELCOL_CHECKSUMS_URL="${OTELCOL_OSS_BASE}/opentelemetry-collector-releases_otelcol-contrib_checksums.txt"

# ── Defaults ──
ENDPOINT=""
AUTHORIZATION=""
PUBLIC_KEY=""
SECRET_KEY=""
SERVICE_NAME=""
PLUGIN_URL="${DEFAULT_PLUGIN_URL}"
INSTALL_DIR=""
CONFIG_PATH=""
ENABLE_PLUGIN=true
TARGET_DIR=""  # Will be set during exporter installation or remain empty if skipped
ENABLE_SKILL_TAGGING=false
SKILLS_ROOTS=""
CUSTOM_TAGS=""
USER_ID=""
ENABLE_DEBUG=false
INSTALLED_VERSION=""  # read from package.json after installation; used for verification and summary

# ── OtelCol-Contrib + ClickHouse defaults ──
ENABLE_OTELCOL=false
CK_ENDPOINT=""
CK_USERNAME=""
CK_PASSWORD=""
CK_DATABASE="clickobserve_service"
OTELCOL_GRPC_ENDPOINT="0.0.0.0:4317"
OTELCOL_HTTP_ENDPOINT="0.0.0.0:4318"
OTELCOL_BINARY=""
DIAG_TRACES=false
DIAG_LOGS=true
DIAG_METRICS=true

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
die()   { echo "ERROR: $*" >&2; exit 1; }

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
need_value() {
  if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
    error "Option $1 requires a value"
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint)           need_value "$@"; ENDPOINT="$2";       shift 2 ;;
    --authorization)      need_value "$@"; AUTHORIZATION="$2";  shift 2 ;;
    --pk)                 need_value "$@"; PUBLIC_KEY="$2";     shift 2 ;;
    --sk)                 need_value "$@"; SECRET_KEY="$2";     shift 2 ;;
    --serviceName)        need_value "$@"; SERVICE_NAME="$2";   shift 2 ;;
    --tags)               need_value "$@"; CUSTOM_TAGS="$2";    shift 2 ;;
    --user-id)            need_value "$@"; USER_ID="$2";       shift 2 ;;
    --plugin-url)         need_value "$@"; PLUGIN_URL="$2";     shift 2 ;;
    --install-dir)        need_value "$@"; INSTALL_DIR="$2";    shift 2 ;;
    --config)             need_value "$@"; CONFIG_PATH="$2";    shift 2 ;;
    --debug)              ENABLE_DEBUG=true; shift ;;
    --skill-tagging-enabled) ENABLE_SKILL_TAGGING=true; shift ;;
    --skills-roots)       need_value "$@"; SKILLS_ROOTS="$2";   shift 2 ;;
    --skip-plugin)        ENABLE_PLUGIN=false; shift ;;
    # ── OtelCol-Contrib + ClickHouse flags ──
    --enable-otelcol)     ENABLE_OTELCOL=true; shift ;;
    --ck-endpoint)        need_value "$@"; CK_ENDPOINT="$2";    shift 2 ;;
    --ck-username)        need_value "$@"; CK_USERNAME="$2";    shift 2 ;;
    --ck-password)        need_value "$@"; CK_PASSWORD="$2";    shift 2 ;;
    --ck-database)        need_value "$@"; CK_DATABASE="$2";    shift 2 ;;
    --otelcol-grpc-endpoint) need_value "$@"; OTELCOL_GRPC_ENDPOINT="$2"; shift 2 ;;
    --otelcol-http-endpoint) need_value "$@"; OTELCOL_HTTP_ENDPOINT="$2"; shift 2 ;;
    --otelcol-binary)     need_value "$@"; OTELCOL_BINARY="$2"; shift 2 ;;
    --diag-traces)        need_value "$@"; DIAG_TRACES="$2";    shift 2 ;;
    --diag-logs)          need_value "$@"; DIAG_LOGS="$2";      shift 2 ;;
    --diag-metrics)       need_value "$@"; DIAG_METRICS="$2";   shift 2 ;;
    --oss-host)           need_value "$@"; OSS_HOST="$2";         shift 2 ;;
    *)
      error "Unknown option: $1"
      exit 1
      ;;
  esac
done

# ── Recompute OSS-derived URLs in case --oss-host was provided ──
OSS_BASE_URL="https://${OSS_HOST}/openclaw-exporter-to-langfuse"
OTELCOL_OSS_BASE="https://${OSS_HOST}/opentelemetry-collector-releases"
OTELCOL_CHECKSUMS_URL="${OTELCOL_OSS_BASE}/opentelemetry-collector-releases_otelcol-contrib_checksums.txt"
if [[ "$PLUGIN_URL" == "$DEFAULT_PLUGIN_URL" ]]; then
  if [[ -n "$PLUGIN_VERSION" ]]; then
    DEFAULT_PLUGIN_URL="${OSS_BASE_URL}/${PLUGIN_VERSION}/openclaw-exporter-to-langfuse.tar.gz"
  else
    DEFAULT_PLUGIN_URL="${OSS_BASE_URL}/openclaw-exporter-to-langfuse.tar.gz"
  fi
  PLUGIN_URL="$DEFAULT_PLUGIN_URL"
fi

print_developer_info

ensure_root_startup

# ── Generate Authorization from pk/sk if provided ──
if [[ -n "$PUBLIC_KEY" && -n "$SECRET_KEY" ]]; then
  AUTHORIZATION="Basic $(echo -n "${PUBLIC_KEY}:${SECRET_KEY}" | base64 | tr -d '\n')"
  info "Generated Authorization from pk/sk"
fi

# ── Validate required parameters ──
MISSING=()

# serviceName is always required
[[ -z "$SERVICE_NAME" ]]  && MISSING+=("--serviceName")

# endpoint and authorization are only required when the exporter is enabled
if [[ "$ENABLE_PLUGIN" == true ]]; then
  [[ -z "$ENDPOINT" ]] && MISSING+=("--endpoint")
  if [[ -z "$AUTHORIZATION" ]]; then
    if [[ -z "$PUBLIC_KEY" || -z "$SECRET_KEY" ]]; then
      MISSING+=("--authorization OR (--pk AND --sk)")
    fi
  fi
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  error "Missing required parameters: ${MISSING[*]}"
  echo ""
  echo "Usage (with pk/sk):"
  echo "  curl -fsSL https://<host>/install.sh | bash -s -- \\"
  echo "    --endpoint \"https://cloud.langfuse.com/api/public/otel/v1/traces\" \\"
  echo "    --pk \"pk-lf-xxx\" \\"
  echo "    --sk \"sk-lf-yyy\" \\"
  echo "    --serviceName \"my-service\""
  echo ""
  echo "Usage (with authorization):"
  echo "  curl -fsSL https://<host>/install.sh | bash -s -- \\"
  echo "    --endpoint \"https://cloud.langfuse.com/api/public/otel/v1/traces\" \\"
  echo "    --authorization \"Basic xxx\" \\"
  echo "    --serviceName \"my-service\""
  echo ""
  echo "OtelCol-Contrib + ClickHouse (optional):"
  echo "  Add --enable-otelcol plus:"
  echo "    --ck-endpoint \"http://<ck-host>:8123\" \\"
  echo "    --ck-username \"default\" \\"
  echo "    --ck-password \"password\" \\"
  echo "    --ck-database \"clickobserve_service\""
  echo ""
  echo "Options:"
  echo "  --skip-plugin          Skip openclaw-exporter-to-langfuse install (otelcol only)"
  echo "  --debug                Enable exporter debug logs (flag, default: false)"
  echo "  --skill-tagging-enabled"
  echo "                         Enable skill tag detection (flag, default: false)"
  echo "  --skills-roots         Comma-separated roots or JSON array string"
  echo "  --tags                 Comma-separated tags or JSON array string"
  echo "  --user-id              Static user ID for traces (overrides OS username default)"
  exit 1
fi

# ── At least one feature must be enabled ──
if [[ "$ENABLE_PLUGIN" == false ]] && [[ "$ENABLE_OTELCOL" == false ]]; then
  error "Nothing to install. Use --enable-otelcol and/or remove --skip-plugin."
  exit 1
fi

# ── Validate otelcol parameters when enabled ──
if [[ "$ENABLE_OTELCOL" == true ]]; then
  OTELCOL_MISSING=()
  [[ -z "$CK_ENDPOINT" ]] && OTELCOL_MISSING+=("--ck-endpoint")
  [[ -z "$CK_USERNAME" ]] && OTELCOL_MISSING+=("--ck-username")
  [[ -z "$CK_PASSWORD" ]] && OTELCOL_MISSING+=("--ck-password")
  if [[ ${#OTELCOL_MISSING[@]} -gt 0 ]]; then
    error "--enable-otelcol requires: ${OTELCOL_MISSING[*]}"
    exit 1
  fi
fi

# ── Check prerequisites ──
info "Checking prerequisites..."

if ! command -v node &>/dev/null; then
  error "Node.js is not installed. Please install Node.js >= 18 first."
  exit 1
fi

NODE_MAJOR=$(node -e "process.stdout.write(String(process.versions.node.split('.')[0]))")
if [[ "$NODE_MAJOR" -lt 18 ]]; then
  error "Node.js >= 18 is required (current: $(node --version))"
  exit 1
fi
ok "Node.js $(node --version)"

if ! command -v npm &>/dev/null; then
  error "npm is not installed."
  exit 1
fi
ok "npm $(npm --version)"

OPENCLAW_CMD="openclaw"
if ! command -v "$OPENCLAW_CMD" &>/dev/null; then
  error "OpenClaw CLI not found. Please install OpenClaw first before installing this exporter."
  exit 1
fi
ok "OpenClaw CLI found"

# ── Report which tarball will be installed ──
if [[ "$PLUGIN_URL" != "$DEFAULT_PLUGIN_URL" ]]; then
  info "Using custom plugin URL: ${PLUGIN_URL}"
elif [[ -n "$PLUGIN_VERSION" ]]; then
  info "Installing exporter ${PLUGIN_VERSION}..."
else
  info "Installing latest exporter..."
fi

# ── Check endpoint connectivity ──
if [[ "$ENABLE_PLUGIN" == true ]]; then
  info "Checking Langfuse endpoint connectivity: ${ENDPOINT}"
  ENDPOINT_HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" "$ENDPOINT" -m 10 2>/dev/null || echo "000")
  if [[ "$ENDPOINT_HTTP_CODE" == "000" ]]; then
    warn "Langfuse endpoint is unreachable (HTTP code: 000)."
    warn "Please check your network connectivity to: ${ENDPOINT}"
    warn "Traces will not be reported if the endpoint is not reachable."
  else
    ok "Langfuse endpoint reachable (HTTP ${ENDPOINT_HTTP_CODE})"
  fi
fi

# ══════════════════════════════════════════════════════
# ── openclaw-exporter-to-langfuse: download, extract, install ──
# ══════════════════════════════════════════════════════
PLUGIN_STATUS="skipped"

if [[ "$ENABLE_PLUGIN" == true ]]; then

# ── Determine install directory ──
# Priority: --install-dir flag > OPENCLAW_STATE_DIR env > running openclaw process user > current user > /opt
if [[ -n "$INSTALL_DIR" ]]; then
  TARGET_DIR="$INSTALL_DIR"
elif [[ -n "${OPENCLAW_STATE_DIR:-}" ]] && [[ -d "$OPENCLAW_STATE_DIR" ]]; then
  TARGET_DIR="${OPENCLAW_STATE_DIR}/extensions/${PLUGIN_NAME}"
else
  # Try to detect from running openclaw process user
  DETECTED_HOME=""
  OPENCLAW_PIDS=$(pgrep -f "openclaw" 2>/dev/null || true)
  OPENCLAW_PID_COUNT=$(echo "$OPENCLAW_PIDS" | grep -c '[0-9]' || true)
  if [[ "$OPENCLAW_PID_COUNT" -eq 0 ]]; then
    die "No running openclaw process found. Please start openclaw first, or specify --install-dir explicitly."
  elif [[ "$OPENCLAW_PID_COUNT" -gt 1 ]]; then
    die "Multiple openclaw processes found (PIDs: $(echo "$OPENCLAW_PIDS" | tr '\n' ' ')). Cannot determine install directory automatically. Please specify --install-dir explicitly."
  fi
  OPENCLAW_PID=$(echo "$OPENCLAW_PIDS" | tr -d '[:space:]')
  OPENCLAW_USER_INST=$(ps -o user= -p "$OPENCLAW_PID" 2>/dev/null || true)
  if [[ -n "$OPENCLAW_USER_INST" ]] && [[ "$OPENCLAW_USER_INST" != "root" ]]; then
    DETECTED_HOME=$(eval echo "~$OPENCLAW_USER_INST")
    if [[ -d "${DETECTED_HOME}/.openclaw" ]]; then
      TARGET_DIR="${DETECTED_HOME}/.openclaw/extensions/${PLUGIN_NAME}"
    fi
  fi
  # Fallback to current user or /opt
  if [[ -z "${TARGET_DIR:-}" ]]; then
    if [[ -d "$REAL_HOME/.openclaw" ]]; then
      TARGET_DIR="$REAL_HOME/.openclaw/extensions/${PLUGIN_NAME}"
    else
      TARGET_DIR="/opt/${PLUGIN_NAME}"
    fi
  fi
fi

info "Install directory: ${TARGET_DIR}"

# ── Clean previous installation (idempotent: re-run overwrites safely) ──
if [[ -d "$TARGET_DIR" ]]; then
  if [[ -z "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]]; then
    info "Target directory exists but is empty, continuing."
  elif [[ -f "$TARGET_DIR/package.json" ]] || [[ -f "$TARGET_DIR/openclaw.plugin.json" ]]; then
    info "Previous installation detected, will overwrite in-place."
  else
    error "Target directory exists but does not look like an exporter installation: ${TARGET_DIR}"
    error "Expected package.json or openclaw.plugin.json inside the directory."
    error "Please verify --install-dir or remove the directory manually."
    exit 1
  fi
fi
mkdir -p "$TARGET_DIR"

# ── Download and extract ──
info "Downloading exporter from ${PLUGIN_URL}..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

if command -v curl &>/dev/null; then
  curl -fsSL -H "Cache-Control: no-cache" "$PLUGIN_URL" -o "$TMP_DIR/plugin.tar.gz"
elif command -v wget &>/dev/null; then
  wget -q --no-cache "$PLUGIN_URL" -O "$TMP_DIR/plugin.tar.gz"
else
  error "Neither curl nor wget is available."
  exit 1
fi
ok "Downloaded"

info "Extracting to ${TARGET_DIR}..."
tar -xzf "$TMP_DIR/plugin.tar.gz" -C "$TMP_DIR"
if [[ -d "$TMP_DIR/${PLUGIN_NAME}" ]]; then
  cp -rf "$TMP_DIR/${PLUGIN_NAME}/." "$TARGET_DIR/"
else
  cp -rf "$TMP_DIR/." "$TARGET_DIR/"
fi
ok "Extracted"

# ── Install npm dependencies for openclaw-exporter-to-langfuse ──
info "Installing npm dependencies (production only)..."
if ! (cd "$TARGET_DIR" && npm install --omit=dev --ignore-scripts 2>&1); then
  error "npm install failed in ${TARGET_DIR}"
  exit 1
fi
ok "Dependencies installed"
PLUGIN_STATUS="installed"

# ── Verify installed version ──
INSTALLED_VERSION=$(node -e "
try {
  const p = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  process.stdout.write(p.version || '');
} catch(e) {}
" "${TARGET_DIR}/package.json" 2>/dev/null || echo "")
if [[ -n "$PLUGIN_VERSION" ]] && [[ -n "$INSTALLED_VERSION" ]]; then
  EXPECTED_VER="${PLUGIN_VERSION#v}"
  if [[ "$INSTALLED_VERSION" != "$EXPECTED_VER" ]]; then
    warn "Version mismatch: expected ${PLUGIN_VERSION}, installed v${INSTALLED_VERSION}"
  else
    ok "Version verified: ${PLUGIN_VERSION}"
  fi
fi

fi  # end ENABLE_PLUGIN

# ══════════════════════════════════════════════════════
# ── OtelCol-Contrib: install, configure, start ──
# ══════════════════════════════════════════════════════
OTELCOL_STATUS="skipped"
OTELCOL_CONFIG_STATUS="skipped"

if [[ "$ENABLE_OTELCOL" == true ]]; then
  info "OtelCol-Contrib integration enabled"

  # ── Step 2a: Check if otelcol-contrib is already installed ──
  OTELCOL_INSTALLED=false
  if command -v otelcol-contrib &>/dev/null; then
    OTELCOL_INSTALLED=true
    OTELCOL_CURRENT_VERSION=$(otelcol-contrib --version 2>&1 | head -1 || echo "unknown")
    ok "otelcol-contrib already installed: ${OTELCOL_CURRENT_VERSION}"
    OTELCOL_STATUS="already_installed"
  fi

  # ── Step 2b: Detect OS and architecture ──
  if [[ "$OTELCOL_INSTALLED" == false ]]; then
    OS_NAME=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64)  ARCH_NAME="amd64" ;;
      aarch64) ARCH_NAME="arm64" ;;
      arm64)   ARCH_NAME="arm64" ;;
      *)
        error "Unsupported architecture: $ARCH"
        error "Please download otelcol-contrib manually from:"
        error "  ${OTELCOL_OSS_BASE}/"
        exit 1
        ;;
    esac

    # Detect package format
    PKG_FORMAT="tar.gz"
    if [[ "$OS_NAME" == "linux" ]]; then
      if command -v rpm &>/dev/null || command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        PKG_FORMAT="rpm"
      elif command -v dpkg &>/dev/null || command -v apt &>/dev/null; then
        PKG_FORMAT="deb"
      fi
    fi

    OTELCOL_ASSET="otelcol-contrib_${OTELCOL_VERSION}_${OS_NAME}_${ARCH_NAME}.${PKG_FORMAT}"
    OTELCOL_DOWNLOAD_URL="${OTELCOL_OSS_BASE}/${OTELCOL_ASSET}"

    info "Detected: OS=${OS_NAME}, Arch=${ARCH_NAME}, Package=${PKG_FORMAT}"

    # ── Step 2c: Download otelcol-contrib ──
    if [[ -n "$OTELCOL_BINARY" ]]; then
      # User provided a local file
      if [[ ! -f "$OTELCOL_BINARY" ]]; then
        error "Specified otelcol-contrib binary not found: $OTELCOL_BINARY"
        exit 1
      fi
      info "Using user-provided otelcol-contrib: $OTELCOL_BINARY"
      OTELCOL_PKG="$OTELCOL_BINARY"
    else
      info "Downloading otelcol-contrib v${OTELCOL_VERSION}..."
      OTELCOL_TMP=$(mktemp -d)
      OTELCOL_PKG="${OTELCOL_TMP}/${OTELCOL_ASSET}"

      DOWNLOAD_OK=false
      if command -v curl &>/dev/null; then
        if curl -fsSL "$OTELCOL_DOWNLOAD_URL" -o "$OTELCOL_PKG" 2>/dev/null; then
          DOWNLOAD_OK=true
        fi
      elif command -v wget &>/dev/null; then
        if wget -q "$OTELCOL_DOWNLOAD_URL" -O "$OTELCOL_PKG" 2>/dev/null; then
          DOWNLOAD_OK=true
        fi
      fi

      if [[ "$DOWNLOAD_OK" != true ]]; then
        error "Failed to download otelcol-contrib. No internet access or OSS is unreachable."
        echo ""
        echo -e "${YELLOW}  Please download manually and re-run with --otelcol-binary:${NC}"
        echo ""
        echo "    wget -O ${OTELCOL_ASSET} ${OTELCOL_DOWNLOAD_URL}"
        echo ""
        echo "  SHA256 checksums: ${OTELCOL_CHECKSUMS_URL}"
        echo ""
        echo "  Then re-run install with:  --otelcol-binary ./${OTELCOL_ASSET}"
        rm -rf "$OTELCOL_TMP"
        exit 1
      fi
      ok "Downloaded ${OTELCOL_ASSET}"

      # Verify sha256 checksum
      info "Verifying checksum..."
      CHECKSUMS_FILE="${OTELCOL_TMP}/checksums.txt"
      CHECKSUM_OK=false
      if curl -fsSL "$OTELCOL_CHECKSUMS_URL" -o "$CHECKSUMS_FILE" 2>/dev/null || \
         wget -q "$OTELCOL_CHECKSUMS_URL" -O "$CHECKSUMS_FILE" 2>/dev/null; then
        EXPECTED_SUM=$(grep -E "^[a-f0-9]+  ${OTELCOL_ASSET}$" "$CHECKSUMS_FILE" | awk '{print $1}')
        if [[ -n "$EXPECTED_SUM" ]]; then
          if command -v sha256sum &>/dev/null; then
            ACTUAL_SUM=$(sha256sum "$OTELCOL_PKG" | awk '{print $1}')
          elif command -v shasum &>/dev/null; then
            ACTUAL_SUM=$(shasum -a 256 "$OTELCOL_PKG" | awk '{print $1}')
          else
            warn "No sha256sum/shasum available, skipping checksum verification"
            CHECKSUM_OK=true
          fi
          if [[ -n "${ACTUAL_SUM:-}" ]]; then
            if [[ "$ACTUAL_SUM" == "$EXPECTED_SUM" ]]; then
              CHECKSUM_OK=true
              ok "Checksum verified"
            else
              error "Checksum mismatch!"
              error "  Expected: $EXPECTED_SUM"
              error "  Actual:   $ACTUAL_SUM"
              rm -rf "$OTELCOL_TMP"
              exit 1
            fi
          fi
        else
          warn "Asset not found in checksums file, skipping verification"
          CHECKSUM_OK=true
        fi
      else
        warn "Could not download checksums file, skipping verification"
        CHECKSUM_OK=true
      fi
    fi

    # ── Step 2d: Install otelcol-contrib ──
    info "Installing otelcol-contrib v${OTELCOL_VERSION}..."

    case "$PKG_FORMAT" in
      rpm)
        if command -v yum &>/dev/null; then
          yum localinstall -y "$OTELCOL_PKG" 2>&1 || { error "yum install failed"; exit 1; }
        elif command -v dnf &>/dev/null; then
          dnf localinstall -y "$OTELCOL_PKG" 2>&1 || { error "dnf install failed"; exit 1; }
        else
          rpm -Uvh "$OTELCOL_PKG" 2>&1 || { error "rpm install failed"; exit 1; }
        fi
        ;;
      deb)
        dpkg -i "$OTELCOL_PKG" 2>&1 || true
        if command -v apt-get &>/dev/null; then
          apt-get install -f -y 2>&1 || { error "apt-get install -f failed"; exit 1; }
        fi
        ;;
      tar.gz)
        OTELCOL_EXTRACT_DIR=$(mktemp -d)
        tar -xzf "$OTELCOL_PKG" -C "$OTELCOL_EXTRACT_DIR"
        if [[ -f "$OTELCOL_EXTRACT_DIR/otelcol-contrib" ]]; then
          cp -f "$OTELCOL_EXTRACT_DIR/otelcol-contrib" /usr/local/bin/otelcol-contrib
          chmod +x /usr/local/bin/otelcol-contrib
        else
          # Some tar.gz bundles may nest the binary
          FOUND_BIN=$(find "$OTELCOL_EXTRACT_DIR" -name "otelcol-contrib" -type f | head -1)
          if [[ -n "$FOUND_BIN" ]]; then
            cp -f "$FOUND_BIN" /usr/local/bin/otelcol-contrib
            chmod +x /usr/local/bin/otelcol-contrib
          else
            error "Could not find otelcol-contrib binary in the archive"
            exit 1
          fi
        fi
        rm -rf "$OTELCOL_EXTRACT_DIR"
        # Create config directory if not exists
        mkdir -p /etc/otelcol-contrib
        ;;
    esac

    # Cleanup temp download
    [[ -n "${OTELCOL_TMP:-}" ]] && rm -rf "$OTELCOL_TMP"

    if command -v otelcol-contrib &>/dev/null; then
      ok "otelcol-contrib installed successfully"
      OTELCOL_STATUS="fresh_install"
    else
      error "otelcol-contrib installation completed but binary not found in PATH"
      exit 1
    fi
  fi

  # ── Step 3: Configure otelcol-contrib config.yaml ──
  OTELCOL_CONFIG_PATH="/etc/otelcol-contrib/config.yaml"
  mkdir -p /etc/otelcol-contrib

  # Append query params to CK endpoint if not already present
  CK_ENDPOINT_FULL="$CK_ENDPOINT"
  if [[ "$CK_ENDPOINT_FULL" != *"?"* ]]; then
    CK_ENDPOINT_FULL="${CK_ENDPOINT_FULL}?dial_timeout=10s&compress=lz4&async_insert=1"
  fi

  if [[ -f "$OTELCOL_CONFIG_PATH" ]]; then
    BACKUP_PATH="${OTELCOL_CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    info "Backing up existing config to ${BACKUP_PATH}"
    cp -f "$OTELCOL_CONFIG_PATH" "$BACKUP_PATH"
  fi

  info "Writing otelcol-contrib config: ${OTELCOL_CONFIG_PATH}"
  tee "$OTELCOL_CONFIG_PATH" > /dev/null << OTELCOL_EOF
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: ${OTELCOL_GRPC_ENDPOINT}
      http:
        endpoint: ${OTELCOL_HTTP_ENDPOINT}
processors:
  batch:
    timeout: 5s
    send_batch_size: 5000
exporters:
  clickhouse:
    endpoint: ${CK_ENDPOINT_FULL}
    username: ${CK_USERNAME}
    password: ${CK_PASSWORD}
    traces_table_name: otel_traces
    logs_table_name: otel_logs
    metrics_tables:
      gauge:
        name: otel_metrics_gauge
      sum:
        name: otel_metrics_sum
      summary:
        name: otel_metrics_summary
      histogram:
        name: otel_metrics_histogram
      exponential_histogram:
        name: otel_metrics_exp_histogram
    create_schema: true
    timeout: 5s
    database: ${CK_DATABASE}
    sending_queue:
      queue_size: 1000
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhouse]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhouse]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhouse]
OTELCOL_EOF
  ok "otelcol-contrib config written"
  OTELCOL_CONFIG_STATUS="configured"

  # ── Step 4: Start/restart otelcol-contrib ──
  info "Starting otelcol-contrib service..."
  if command -v systemctl &>/dev/null; then
    if systemctl restart otelcol-contrib 2>&1; then
      ok "otelcol-contrib service restarted (systemctl)"
    else
      warn "systemctl restart failed. Trying 'service' command..."
      if service otelcol-contrib restart 2>&1; then
        ok "otelcol-contrib service restarted (service)"
      else
        warn "otelcol-contrib service restart failed. Please start it manually."
      fi
    fi
  elif command -v service &>/dev/null; then
    if service otelcol-contrib restart 2>&1; then
      ok "otelcol-contrib service restarted"
    else
      warn "otelcol-contrib service restart failed. Please start it manually."
    fi
  else
    warn "No systemctl/service found. Please start otelcol-contrib manually:"
    echo "  otelcol-contrib --config=${OTELCOL_CONFIG_PATH}"
  fi

  # Verify service is running
  sleep 2
  if command -v systemctl &>/dev/null && systemctl is-active --quiet otelcol-contrib 2>/dev/null; then
    ok "otelcol-contrib is running"
  elif pgrep -x otelcol-contrib &>/dev/null; then
    ok "otelcol-contrib process detected"
  else
    warn "Could not verify otelcol-contrib is running. Please check manually."
  fi
fi

# ══════════════════════════════════════════════════════
# ── diagnostics-otel: locate, install deps, configure ──
# ══════════════════════════════════════════════════════
DIAG_OTEL_DIR=""
DIAG_OTEL_STATUS="skipped"

if [[ "$ENABLE_OTELCOL" == true ]]; then
  info "Locating ${DIAG_PLUGIN_NAME} extension..."

  find_diag_otel() {
    local candidate="$1"
    if [[ -d "$candidate" ]] && [[ -f "$candidate/package.json" ]]; then
      DIAG_OTEL_DIR="$candidate"
      return 0
    fi
    return 1
  }

  # 1) OPENCLAW_BUNDLED_PLUGINS_DIR env
  if [[ -n "${OPENCLAW_BUNDLED_PLUGINS_DIR:-}" ]]; then
    find_diag_otel "${OPENCLAW_BUNDLED_PLUGINS_DIR}/${DIAG_PLUGIN_NAME}" || true
  fi

  # 2) Sibling of openclaw executable
  if [[ -z "$DIAG_OTEL_DIR" ]] && command -v openclaw &>/dev/null; then
    OPENCLAW_BIN=$(command -v openclaw)
    OPENCLAW_BIN_REAL=$(realpath "$OPENCLAW_BIN" 2>/dev/null || readlink -f "$OPENCLAW_BIN" 2>/dev/null || echo "$OPENCLAW_BIN")
    OPENCLAW_BIN_DIR=$(dirname "$OPENCLAW_BIN_REAL")
    find_diag_otel "${OPENCLAW_BIN_DIR}/extensions/${DIAG_PLUGIN_NAME}" || true
    if [[ -z "$DIAG_OTEL_DIR" ]]; then
      OPENCLAW_PARENT=$(dirname "$OPENCLAW_BIN_DIR")
      find_diag_otel "${OPENCLAW_PARENT}/extensions/${DIAG_PLUGIN_NAME}" || true
      find_diag_otel "${OPENCLAW_PARENT}/lib/node_modules/openclaw/extensions/${DIAG_PLUGIN_NAME}" || true
    fi
  fi

  # 3) npm global root
  if [[ -z "$DIAG_OTEL_DIR" ]] && command -v npm &>/dev/null; then
    NPM_GLOBAL_ROOT=$(npm root -g 2>/dev/null || true)
    if [[ -n "$NPM_GLOBAL_ROOT" ]]; then
      find_diag_otel "${NPM_GLOBAL_ROOT}/openclaw/extensions/${DIAG_PLUGIN_NAME}" || true
    fi
  fi

  # 4) OPENCLAW_STATE_DIR / ~/.openclaw
  if [[ -z "$DIAG_OTEL_DIR" ]]; then
    if [[ -n "${OPENCLAW_STATE_DIR:-}" ]]; then
      find_diag_otel "${OPENCLAW_STATE_DIR}/extensions/${DIAG_PLUGIN_NAME}" || true
    fi
    if [[ -z "$DIAG_OTEL_DIR" ]]; then
      find_diag_otel "$REAL_HOME/.openclaw/extensions/${DIAG_PLUGIN_NAME}" || true
    fi
  fi

  if [[ -n "$DIAG_OTEL_DIR" ]]; then
    ok "Found ${DIAG_PLUGIN_NAME} at: ${DIAG_OTEL_DIR}"

    # Install dependencies if node_modules is missing
    if [[ ! -d "${DIAG_OTEL_DIR}/node_modules" ]]; then
      info "Installing ${DIAG_PLUGIN_NAME} dependencies (first-time setup)..."
      if ! (cd "$DIAG_OTEL_DIR" && npm install --omit=dev --ignore-scripts 2>&1); then
        warn "${DIAG_PLUGIN_NAME} npm install failed. You may need to install manually: cd ${DIAG_OTEL_DIR} && npm install --omit=dev"
        DIAG_OTEL_STATUS="npm_failed"
      else
        ok "${DIAG_PLUGIN_NAME} dependencies installed"
        DIAG_OTEL_STATUS="fresh_install"
      fi
    else
      ok "${DIAG_PLUGIN_NAME} dependencies already present"
      DIAG_OTEL_STATUS="already_installed"
    fi
  else
    warn "${DIAG_PLUGIN_NAME} not found. Config will be written but the plugin may not load until OpenClaw is properly installed."
    DIAG_OTEL_STATUS="not_found"
  fi
fi

# ── Determine openclaw.json path ──
# Priority: --config flag > OPENCLAW_STATE_DIR env > running openclaw process user > current user
if [[ -n "${CONFIG_PATH}" ]]; then
  # User provided explicit config path
  if [[ ! -f "$CONFIG_PATH" ]]; then
    error "Config file not found at specified path: ${CONFIG_PATH}"
    exit 1
  fi
elif [[ -n "${OPENCLAW_STATE_DIR:-}" ]]; then
  CONFIG_PATH="${OPENCLAW_STATE_DIR}/openclaw.json"
else
  # Try to find the user running openclaw process (best-effort, no error if absent/multiple)
  _OC_PID=$(pgrep -f "openclaw" 2>/dev/null | head -1 || true)
  if [[ -n "$_OC_PID" ]]; then
    OPENCLAW_USER=$(ps -o user= -p "$_OC_PID" 2>/dev/null || true)
    if [[ -n "$OPENCLAW_USER" ]] && [[ "$OPENCLAW_USER" != "root" ]]; then
      USER_HOME=$(eval echo "~$OPENCLAW_USER")
      if [[ -f "${USER_HOME}/.openclaw/openclaw.json" ]]; then
        CONFIG_PATH="${USER_HOME}/.openclaw/openclaw.json"
      fi
    fi
  fi
fi

# Fallback to current user's home directory
if [[ -z "${CONFIG_PATH:-}" ]]; then
  if [[ -f "$REAL_HOME/.openclaw/openclaw.json" ]]; then
    CONFIG_PATH="$REAL_HOME/.openclaw/openclaw.json"
  fi
fi

# ── Config file must exist ──
if [[ -z "${CONFIG_PATH:-}" ]] || [[ ! -f "$CONFIG_PATH" ]]; then
  error "Cannot find openclaw.json configuration file."
  echo ""
  echo "Searched locations:"
  if [[ -n "${OPENCLAW_STATE_DIR:-}" ]]; then
    echo "  - ${OPENCLAW_STATE_DIR}/openclaw.json"
  fi
  if pgrep -f "openclaw" &>/dev/null; then
    _OC_PID=$(pgrep -f "openclaw" 2>/dev/null | head -1 || true)
    OPENCLAW_USER=$(ps -o user= -p "$_OC_PID" 2>/dev/null || true)
    if [[ -n "$OPENCLAW_USER" ]] && [[ "$OPENCLAW_USER" != "root" ]]; then
      USER_HOME=$(eval echo "~$OPENCLAW_USER")
      echo "  - ${USER_HOME}/.openclaw/openclaw.json (openclaw process user)"
    fi
  fi
  echo "  - $REAL_HOME/.openclaw/openclaw.json (current user)"
  echo ""
  echo "Please ensure OpenClaw is installed and has been run at least once."
  echo "Alternatively, you can specify the config path manually:"
  echo ""
  echo "  --config /path/to/openclaw.json"
  echo "  or"
  echo "  OPENCLAW_STATE_DIR=/path/to/config bash install.sh ..."
  echo ""
  echo "Or create the config file at one of the locations above."
  exit 1
fi

info "Updating config: ${CONFIG_PATH}"

# ── Update openclaw.json using inline Node.js ──
DIAG_CHANGES=$(node -e "
const fs = require('fs');
const configPath     = process.argv[1];
const pluginName     = process.argv[2];
const installDir     = process.argv[3];
const endpoint       = process.argv[4];
const authorization  = process.argv[5];
const serviceName    = process.argv[6];
const enableOtelcol  = process.argv[7] === 'true';
const diagPluginName = process.argv[8];
const diagTraces     = process.argv[9] === 'true';
const diagLogs       = process.argv[10] === 'true';
const diagMetrics    = process.argv[11] === 'true';
const otelcolHttpEp  = process.argv[12];
const enablePlugin   = process.argv[13] === 'true';
const enableSkillTagging = process.argv[14] === 'true';
const skillsRootsArg  = process.argv[15];
const enableDebug     = process.argv[16] === 'true';
const tagsArg         = process.argv[17];
const userIdArg       = process.argv[18];

let config = {};
try {
  config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
  if (e.code !== 'ENOENT') throw e;
}

if (!config.plugins) config.plugins = {};
if (!Array.isArray(config.plugins.allow)) config.plugins.allow = [];
if (!config.plugins.load) config.plugins.load = {};
if (!Array.isArray(config.plugins.load.paths)) config.plugins.load.paths = [];
if (!config.plugins.entries) config.plugins.entries = {};

// ── openclaw-exporter-to-langfuse (when enabled) ──
if (enablePlugin) {
  if (!config.plugins.allow.includes(pluginName)) {
    config.plugins.allow.push(pluginName);
  }
  const paths = config.plugins.load.paths;
  const idx = paths.findIndex(p => p.includes(pluginName));
  if (idx >= 0) paths[idx] = installDir;
  else paths.push(installDir);

  const pluginHeaders = {};
  if (authorization) {
    pluginHeaders['Authorization'] = authorization;
  }
  const existingEntry = config.plugins.entries[pluginName];
  const existingPluginConfig =
    existingEntry && existingEntry.config && typeof existingEntry.config === 'object'
      ? existingEntry.config
      : {};
  const nextPluginConfig = {
    ...existingPluginConfig,
    endpoint,
    headers: pluginHeaders,
    serviceName,
    debug:
      typeof existingPluginConfig.debug === 'boolean'
        ? existingPluginConfig.debug
        : false,
    batchSize:
      typeof existingPluginConfig.batchSize === 'number'
      && Number.isFinite(existingPluginConfig.batchSize)
        ? existingPluginConfig.batchSize
        : 10,
    flushIntervalMs:
      typeof existingPluginConfig.flushIntervalMs === 'number'
      && Number.isFinite(existingPluginConfig.flushIntervalMs)
        ? existingPluginConfig.flushIntervalMs
        : 5000,
    skillTaggingEnabled:
      typeof existingPluginConfig.skillTaggingEnabled === 'boolean'
        ? existingPluginConfig.skillTaggingEnabled
        : false
  };
  if (enableSkillTagging) {
    nextPluginConfig.skillTaggingEnabled = true;
  }
  if (enableDebug) {
    nextPluginConfig.debug = true;
  }
  if (Array.isArray(existingPluginConfig.enabledHooks)) {
    nextPluginConfig.enabledHooks = existingPluginConfig.enabledHooks;
  }
  if (Array.isArray(existingPluginConfig.skillsRoots)) {
    nextPluginConfig.skillsRoots = existingPluginConfig.skillsRoots;
  }
  if (Array.isArray(existingPluginConfig.tags)) {
    nextPluginConfig.tags = existingPluginConfig.tags;
  }
  if (typeof existingPluginConfig.userId === 'string') {
    nextPluginConfig.userId = existingPluginConfig.userId;
  }

  const normalizeSkillRoot = (value) => {
    if (typeof value !== 'string') return '';
    const trimmedValue = value.trim();
    if (!trimmedValue) return '';
    return trimmedValue.replace(/\/+$/, '') || '/';
  };

  if (typeof skillsRootsArg === 'string') {
    const trimmed = skillsRootsArg.trim();
    if (trimmed.startsWith('[')) {
      try {
        const parsed = JSON.parse(trimmed);
        if (Array.isArray(parsed)) {
          nextPluginConfig.skillsRoots = parsed
            .map((x) => normalizeSkillRoot(typeof x === 'string' ? x : String(x)))
            .filter(Boolean);
        }
      } catch {
        // Ignore invalid JSON; keep previous/default skillsRoots.
      }
    } else if (trimmed) {
      nextPluginConfig.skillsRoots = trimmed
        .split(',')
        .map((x) => normalizeSkillRoot(x))
        .filter(Boolean);
    }
  }

  if (Array.isArray(nextPluginConfig.skillsRoots)) {
    nextPluginConfig.skillsRoots = nextPluginConfig.skillsRoots
      .map(normalizeSkillRoot)
      .filter((value, index, arr) => value && arr.indexOf(value) === index);
    if (nextPluginConfig.skillsRoots.length === 0) {
      delete nextPluginConfig.skillsRoots;
    }
  }

  const normalizeTag = (value) => {
    if (typeof value !== 'string') return '';
    return value.trim();
  };

  if (typeof tagsArg === 'string') {
    const trimmed = tagsArg.trim();
    if (trimmed.startsWith('[')) {
      try {
        const parsed = JSON.parse(trimmed);
        if (Array.isArray(parsed)) {
          nextPluginConfig.tags = parsed
            .map((x) => normalizeTag(typeof x === 'string' ? x : String(x)))
            .filter(Boolean);
        }
      } catch {
        // Ignore invalid JSON; keep previous/default tags.
      }
    } else if (trimmed) {
      nextPluginConfig.tags = trimmed
        .split(',')
        .map((x) => normalizeTag(x))
        .filter(Boolean);
    }
  }

  if (Array.isArray(nextPluginConfig.tags)) {
    nextPluginConfig.tags = nextPluginConfig.tags
      .map(normalizeTag)
      .filter((value, index, arr) => value && arr.indexOf(value) === index);
    if (nextPluginConfig.tags.length === 0) {
      delete nextPluginConfig.tags;
    }
  }

  if (typeof userIdArg === 'string') {
    const trimmed = userIdArg.trim();
    if (trimmed) {
      nextPluginConfig.userId = trimmed;
    }
  }

  if (typeof nextPluginConfig.userId === 'string') {
    const trimmedUserId = nextPluginConfig.userId.trim();
    if (trimmedUserId) {
      nextPluginConfig.userId = trimmedUserId;
    } else {
      delete nextPluginConfig.userId;
    }
  }
  config.plugins.entries[pluginName] = {
    enabled: true,
    hooks: { allowConversationAccess: true },
    config: nextPluginConfig
  };
}

// ── diagnostics-otel (when otelcol-contrib is enabled) ──
const diagChanges = [];
if (enableOtelcol) {
  // plugins.allow
  if (!config.plugins.allow.includes(diagPluginName)) {
    config.plugins.allow.push(diagPluginName);
    diagChanges.push('added to plugins.allow');
  }

  // plugins.entries
  const existingEntry = config.plugins.entries[diagPluginName];
  if (existingEntry) {
    if (!existingEntry.enabled) {
      existingEntry.enabled = true;
      diagChanges.push('enabled in plugins.entries');
    }
  } else {
    config.plugins.entries[diagPluginName] = { enabled: true };
    diagChanges.push('added to plugins.entries');
  }

  // diagnostics section
  if (!config.diagnostics) config.diagnostics = {};
  const prevDiagEnabled = config.diagnostics.enabled;
  config.diagnostics.enabled = true;
  if (!prevDiagEnabled) diagChanges.push('diagnostics.enabled -> true');

  if (!config.diagnostics.otel) config.diagnostics.otel = {};
  const otel = config.diagnostics.otel;

  const prevOtelEnabled = otel.enabled;
  otel.enabled = true;
  if (!prevOtelEnabled) diagChanges.push('diagnostics.otel.enabled -> true');

  // endpoint: point to local otelcol-contrib HTTP receiver
  const diagEndpoint = 'http://localhost:' + otelcolHttpEp.split(':').pop();
  const prevEndpoint = otel.endpoint;
  otel.endpoint = diagEndpoint;
  if (prevEndpoint && prevEndpoint !== diagEndpoint) diagChanges.push('diagnostics.otel.endpoint updated');

  if (!otel.protocol) otel.protocol = 'http/protobuf';

  otel.serviceName = serviceName;

  // traces/logs/metrics
  const prevTraces = otel.traces;
  otel.traces = diagTraces;
  if (prevTraces !== undefined && prevTraces !== diagTraces) diagChanges.push('diagnostics.otel.traces -> ' + diagTraces);

  const prevLogs = otel.logs;
  otel.logs = diagLogs;
  if (prevLogs !== undefined && prevLogs !== diagLogs) diagChanges.push('diagnostics.otel.logs -> ' + diagLogs);

  const prevMetrics = otel.metrics;
  otel.metrics = diagMetrics;
  if (prevMetrics !== undefined && prevMetrics !== diagMetrics) diagChanges.push('diagnostics.otel.metrics -> ' + diagMetrics);

  if (diagChanges.length === 0) diagChanges.push('no changes needed');
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n', 'utf8');
process.stdout.write(diagChanges.join('|'));
" \
  "$CONFIG_PATH" \
  "$PLUGIN_NAME" \
  "$TARGET_DIR" \
  "$ENDPOINT" \
  "$AUTHORIZATION" \
  "$SERVICE_NAME" \
  "$ENABLE_OTELCOL" \
  "$DIAG_PLUGIN_NAME" \
  "$DIAG_TRACES" \
  "$DIAG_LOGS" \
  "$DIAG_METRICS" \
  "$OTELCOL_HTTP_ENDPOINT" \
  "$ENABLE_PLUGIN" \
  "$ENABLE_SKILL_TAGGING" \
  "$SKILLS_ROOTS" \
  "$ENABLE_DEBUG" \
  "$CUSTOM_TAGS" \
  "$USER_ID"
)

ok "Config updated"

# ── Restart gateway ──
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

  if [[ "$ENABLE_DEBUG" == true ]] && [[ -n "$restart_output" ]]; then
    warn "Gateway restart output: ${restart_output}"
  fi

  echo ""
  echo -e "${YELLOW}  ⚠  Gateway restart failed.${NC}"
  echo -e "     Please restart manually: ${CYAN}openclaw gateway restart${NC}"
  if [[ -n "$user_restart_cmd" ]]; then
    echo -e "     Or run as service user: ${CYAN}${user_restart_cmd}${NC}"
  fi
  if [[ "$restart_output" == *"Cannot access user instance remotely"* ]]; then
    echo -e "     Detected user-systemd access issue; run the command in an interactive shell."
  fi
  echo ""
  echo -e "     If the issue persists, run: ${RED}openclaw doctor${NC}"
  echo -e "     This command will diagnose and report common configuration issues."
  echo ""
  return 1
}

info "Restarting OpenClaw gateway..."
restart_gateway || true

# ── Summary ──
echo ""
print_developer_info
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ Installation completed successfully!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
echo "  Config file:   ${CONFIG_PATH}"
echo "  Endpoint:      ${ENDPOINT}"
echo "  Service name:  ${SERVICE_NAME}"
if [[ -n "${INSTALLED_VERSION:-}" ]]; then
  echo "  Exporter ver:  v${INSTALLED_VERSION}"
elif [[ -n "$PLUGIN_VERSION" ]]; then
  echo "  Exporter ver:  ${PLUGIN_VERSION}"
fi
echo ""

if [[ "$ENABLE_PLUGIN" == true ]]; then
  echo -e "${CYAN}  ── openclaw-exporter-to-langfuse ──${NC}"
  echo -e "  Status:        ${GREEN}${PLUGIN_STATUS}${NC}"
  echo "  Install dir:   ${TARGET_DIR}"
  echo ""
else
  echo -e "${CYAN}  ── openclaw-exporter-to-langfuse ──${NC}"
  echo -e "  Status:        ${YELLOW}skipped (--skip-plugin)${NC}"
  echo ""
fi

if [[ "$ENABLE_OTELCOL" == true ]]; then
  echo -e "${CYAN}  ── otelcol-contrib (ClickHouse) ──${NC}"
  case "$OTELCOL_STATUS" in
    fresh_install)
      echo -e "  Status:        ${GREEN}Newly installed${NC} (v${OTELCOL_VERSION})"
      ;;
    already_installed)
      echo -e "  Status:        ${GREEN}Already installed${NC}"
      ;;
  esac
  echo "  Config:        ${OTELCOL_CONFIG_PATH:-/etc/otelcol-contrib/config.yaml}"
  echo "  CK endpoint:   ${CK_ENDPOINT}"
  echo "  CK database:   ${CK_DATABASE}"
  echo ""

  echo -e "${CYAN}  ── diagnostics-otel ──${NC}"
  case "$DIAG_OTEL_STATUS" in
    fresh_install)
      echo -e "  Status:        ${GREEN}Newly installed${NC} (npm dependencies installed)"
      echo "  Location:      ${DIAG_OTEL_DIR}"
      ;;
    already_installed)
      echo -e "  Status:        ${GREEN}Already installed${NC}"
      echo "  Location:      ${DIAG_OTEL_DIR}"
      ;;
    npm_failed)
      echo -e "  Status:        ${YELLOW}Dependencies install failed${NC}"
      echo "  Location:      ${DIAG_OTEL_DIR}"
      echo "                 Please run manually: cd ${DIAG_OTEL_DIR} && npm install --omit=dev"
      ;;
    not_found)
      echo -e "  Status:        ${YELLOW}Exporter directory not found${NC}"
      echo "                 Config written; will activate when OpenClaw is installed."
      ;;
  esac
  echo "  Traces:        ${DIAG_TRACES}"
  echo "  Logs:          ${DIAG_LOGS}"
  echo "  Metrics:       ${DIAG_METRICS}"

  # Show config changes
  if [[ -n "${DIAG_CHANGES:-}" ]] && [[ "$DIAG_CHANGES" != "no changes needed" ]]; then
    echo -e "  Config changes: ${YELLOW}${DIAG_CHANGES//|/, }${NC}"
  else
    echo -e "  Config changes: ${GREEN}No changes needed (already configured)${NC}"
  fi
  echo ""
fi
