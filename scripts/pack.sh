#!/usr/bin/env bash
set -euo pipefail

PLUGIN_NAME="openclaw-exporter-to-langfuse"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${PROJECT_DIR}/release"

cd "$PROJECT_DIR"

echo "==> Installing dependencies..."
npm ci --ignore-scripts

echo "==> Syncing version from VERSION file..."
npm run version-sync

echo "==> Building TypeScript..."
npm run build

echo "==> Preparing release directory..."
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/staging/${PLUGIN_NAME}"

cp -r dist             "$OUTPUT_DIR/staging/${PLUGIN_NAME}/"
cp    package.json     "$OUTPUT_DIR/staging/${PLUGIN_NAME}/"
cp    package-lock.json "$OUTPUT_DIR/staging/${PLUGIN_NAME}/"
cp    openclaw.plugin.json "$OUTPUT_DIR/staging/${PLUGIN_NAME}/"
cp    VERSION          "$OUTPUT_DIR/staging/${PLUGIN_NAME}/"
cp    index.ts         "$OUTPUT_DIR/staging/${PLUGIN_NAME}/"
[ -f tsconfig.json ] && cp tsconfig.json "$OUTPUT_DIR/staging/${PLUGIN_NAME}/"

echo "==> Stripping macOS extended attributes..."
if command -v xattr &>/dev/null; then
  xattr -cr "$OUTPUT_DIR/staging/${PLUGIN_NAME}" 2>/dev/null || true
fi

echo "==> Creating tarball..."
COPYFILE_DISABLE=1 tar -czf "$OUTPUT_DIR/${PLUGIN_NAME}.tar.gz" \
  --no-xattrs \
  -C "$OUTPUT_DIR/staging" \
  "${PLUGIN_NAME}" 2>/dev/null || \
COPYFILE_DISABLE=1 tar -czf "$OUTPUT_DIR/${PLUGIN_NAME}.tar.gz" \
  -C "$OUTPUT_DIR/staging" \
  "${PLUGIN_NAME}"

rm -rf "$OUTPUT_DIR/staging"

TARBALL="$OUTPUT_DIR/${PLUGIN_NAME}.tar.gz"
SIZE=$(du -sh "$TARBALL" | cut -f1)

# ── Read version ──
VERSION=$(cat "$PROJECT_DIR/VERSION" | tr -d '[:space:]')
if [[ -z "$VERSION" ]]; then
  echo "ERROR: VERSION file is empty or missing — cannot generate versioned artifacts" >&2
  exit 1
fi

echo ""
echo "==> Generating versioned release artifacts (v${VERSION})..."
VERSIONED_DIR="${OUTPUT_DIR}/v${VERSION}"
mkdir -p "${VERSIONED_DIR}"

# Move tarball into versioned directory
mv "${TARBALL}" "${VERSIONED_DIR}/${PLUGIN_NAME}.tar.gz"

# Generate versioned install.sh — bake PLUGIN_VERSION="v${VERSION}" into the script
# Matches: PLUGIN_VERSION="<anything>" (empty or pre-set)
# Produces: PLUGIN_VERSION="v${VERSION}"
sed "s/^PLUGIN_VERSION=\".*\"$/PLUGIN_VERSION=\"v${VERSION}\"/" \
  "${SCRIPT_DIR}/install.sh" > "${VERSIONED_DIR}/install.sh"
chmod +x "${VERSIONED_DIR}/install.sh"

# Verify the substitution actually worked
BAKED_VERSION=$(grep '^PLUGIN_VERSION=' "${VERSIONED_DIR}/install.sh" | head -1)
if echo "$BAKED_VERSION" | grep -q "\"v${VERSION}\""; then
  echo "==> Verified PLUGIN_VERSION=\"v${VERSION}\" in versioned install.sh"
else
  echo "ERROR: PLUGIN_VERSION substitution failed in '${VERSIONED_DIR}/install.sh'" >&2
  echo "       Got: ${BAKED_VERSION}" >&2
  exit 1
fi

# Generate versioned uninstall.sh — bake SELF_VERSION="v${VERSION}" into the script
# Matches: SELF_VERSION="<anything>"
# Produces: SELF_VERSION="v${VERSION}"
sed "s/^SELF_VERSION=\"[^\"]*\"/SELF_VERSION=\"v${VERSION}\"/" \
  "${SCRIPT_DIR}/uninstall.sh" > "${VERSIONED_DIR}/uninstall.sh"
chmod +x "${VERSIONED_DIR}/uninstall.sh"

# Verify uninstall.sh substitution
BAKED_SELF_VERSION=$(grep '^SELF_VERSION=' "${VERSIONED_DIR}/uninstall.sh" | head -1)
if echo "$BAKED_SELF_VERSION" | grep -q "^SELF_VERSION=\"v${VERSION}\""; then
  echo "==> Verified SELF_VERSION=\"v${VERSION}\" in versioned uninstall.sh"
else
  echo "ERROR: SELF_VERSION substitution failed in '${VERSIONED_DIR}/uninstall.sh'" >&2
  echo "       Got: ${BAKED_SELF_VERSION}" >&2
  exit 1
fi

# Generate versioned INSTALLATION.md — bake {{EXPORTER_VERSION}} into the markdown
sed "s/{{EXPORTER_VERSION}}/v${VERSION}/g" \
  "${SCRIPT_DIR}/VERSIONED_INSTALLATION.md" > "${VERSIONED_DIR}/INSTALLATION.md"
echo "==> Generated ${VERSIONED_DIR}/INSTALLATION.md ({{EXPORTER_VERSION}} → v${VERSION})"

# Create latest/ directory — identical to the versioned directory, always points to current release
LATEST_DIR="${OUTPUT_DIR}/latest"
mkdir -p "${LATEST_DIR}"
cp "${VERSIONED_DIR}/install.sh"        "${LATEST_DIR}/install.sh"
cp "${VERSIONED_DIR}/uninstall.sh"      "${LATEST_DIR}/uninstall.sh"
cp "${VERSIONED_DIR}/INSTALLATION.md"   "${LATEST_DIR}/INSTALLATION.md"
cp "${VERSIONED_DIR}/${PLUGIN_NAME}.tar.gz" "${LATEST_DIR}/${PLUGIN_NAME}.tar.gz"
echo "==> Created ${LATEST_DIR}/ (mirrors v${VERSION}/)"

# Copy shared docs to release root
if [[ -f "${SCRIPT_DIR}/version-compat.json" ]]; then
  cp "${SCRIPT_DIR}/version-compat.json" "${OUTPUT_DIR}/version-compat.json"
fi
cp "${SCRIPT_DIR}/INSTALLATION.md" "${OUTPUT_DIR}/INSTALLATION.md"

echo ""
echo "✅ Release artifacts:"
echo ""
echo "  Root:"
echo "   ${OUTPUT_DIR}/version-compat.json  (if present)"
echo "   ${OUTPUT_DIR}/INSTALLATION.md"
echo ""
echo "  Latest (mirrors v${VERSION}/):"
echo "   ${LATEST_DIR}/install.sh"
echo "   ${LATEST_DIR}/uninstall.sh"
echo "   ${LATEST_DIR}/INSTALLATION.md"
echo "   ${LATEST_DIR}/${PLUGIN_NAME}.tar.gz"
echo ""
echo "  Versioned (v${VERSION}):"
echo "   ${VERSIONED_DIR}/install.sh         ← PLUGIN_VERSION=\"v${VERSION}\""
echo "   ${VERSIONED_DIR}/uninstall.sh       ← SELF_VERSION=\"v${VERSION}\""
echo "   ${VERSIONED_DIR}/INSTALLATION.md    ← {{EXPORTER_VERSION}} → v${VERSION}"
echo "   ${VERSIONED_DIR}/${PLUGIN_NAME}.tar.gz  (${SIZE})"
echo ""
echo "Upload to OSS:"
echo "  Root:      oss://<bucket>/openclaw-exporter-to-langfuse/"
echo "  Latest:    oss://<bucket>/openclaw-exporter-to-langfuse/latest/"
echo "  Versioned: oss://<bucket>/openclaw-exporter-to-langfuse/v${VERSION}/"
