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

echo ""
echo "✅ Tarball created:"
echo "   Path: ${TARBALL}"
echo "   Size: ${SIZE}"
echo ""
echo "Upload this file and install.sh to your OSS bucket, then users can run:"
echo ""
echo "  With pk/sk (recommended):"
echo "   curl -fsSL https://<your-oss>/install.sh | bash -s -- \\"
echo "     --endpoint \"https://cloud.langfuse.com/api/public/otel/v1/traces\" \\"
echo "     --pk \"pk-lf-xxx\" \\"
echo "     --sk \"sk-lf-yyy\" \\"
echo "     --serviceName \"...\" \\"
echo "     --skill-tagging-enabled \\"
echo "     --skills-roots \"/opt/git/openclaw/skills/custom/skills\""
echo ""
echo "  With authorization:"
echo "   curl -fsSL https://<your-oss>/install.sh | bash -s -- \\"
echo "     --endpoint \"https://cloud.langfuse.com/api/public/otel/v1/traces\" \\"
echo "     --authorization \"Basic xxx\" \\"
echo "     --serviceName \"...\" \\"
echo "     --skill-tagging-enabled \\"
echo "     --skills-roots \"/opt/git/openclaw/skills/custom/skills\""
echo ""
echo "  Optional install flags:"
echo "     --debug"
echo "     --skill-tagging-enabled"
echo "     --skills-roots \"<csv paths or JSON array string>\""
