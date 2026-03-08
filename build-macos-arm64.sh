#!/usr/bin/env bash
# build-macos-arm64.sh — Build FoundationDB for macOS arm64 and publish to
# https://github.com/FoundryFabric/foundationdb
#
# Usage: ./build-macos-arm64.sh <version>
# Example: ./build-macos-arm64.sh 7.4.6
#
# Prerequisites: brew install cmake ninja openssl@3 lz4 mono python@3

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>  (e.g. $0 7.4.6)"
  exit 1
fi

REPO="FoundryFabric/foundationdb"
PLATFORM="darwin-arm64"
WORKDIR="$HOME/foundationdb-build-${VERSION}"
BUILD_DIR="$WORKDIR/build"
OPENSSL_PREFIX="$(brew --prefix openssl@3)"

echo "======================================================"
echo "  Building FoundationDB ${VERSION} for macOS arm64"
echo "======================================================"

# ── 1. Clone source ────────────────────────────────────────────────────────────
if [[ ! -d "$WORKDIR/.git" ]]; then
  echo ""
  echo "==> Cloning apple/foundationdb at tag ${VERSION}..."
  git clone --depth=1 --branch "${VERSION}" https://github.com/apple/foundationdb.git "$WORKDIR"
else
  echo ""
  echo "==> Source already cloned at $WORKDIR, skipping clone."
fi
cd "$WORKDIR"

# ── 2. Apply source patches ────────────────────────────────────────────────────
echo ""
echo "==> Applying macOS arm64 source patches..."

# Patch: add alignas(8) to all const StringRef/KeyRef global variable definitions.
# Required because StringRef uses #pragma pack(4), giving it 4-byte alignment despite
# containing an 8-byte pointer. Apple ld 1230+ (Xcode 16 / macOS 15) enforces
# 8-byte pointer alignment for globals.
python3 << 'PYEOF'
import re, os, sys

dirs = ['fdbrpc', 'fdbclient', 'flow', 'fdbserver']
var_pattern  = re.compile(r'^(?:alignas\(8\) )?const (StringRef|KeyRef)\s+\w+\s*(?:=|;)')
func_pattern = re.compile(r'^(?:alignas\(8\) )?const (StringRef|KeyRef)\s+\w+\s*\(')

total_added = total_fixed = 0
for d in dirs:
    for root, _, files in os.walk(d):
        if 'build' in root:
            continue
        for fname in files:
            if not fname.endswith('.cpp') or fname.endswith('.g.cpp'):
                continue
            fpath = os.path.join(root, fname)
            with open(fpath, 'r', errors='replace') as f:
                lines = f.readlines()
            new_lines = []
            changed = 0
            for line in lines:
                if func_pattern.match(line) and line.startswith('alignas(8) '):
                    line = line[len('alignas(8) '):]
                    changed += 1; total_fixed += 1
                elif var_pattern.match(line) and not line.startswith('alignas(8) '):
                    line = 'alignas(8) ' + line
                    changed += 1; total_added += 1
                new_lines.append(line)
            if changed:
                with open(fpath, 'w') as f:
                    f.writelines(new_lines)

print(f"  alignas(8) patch: added to {total_added} globals, removed from {total_fixed} false positives")
PYEOF

# ── 3. CMake configure ─────────────────────────────────────────────────────────
echo ""
echo "==> Configuring cmake..."
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cmake .. \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_JAVA_BINDING=OFF \
  -DBUILD_GO_BINDING=OFF \
  -DBUILD_RUBY_BINDING=OFF \
  -DBUILD_DOCUMENTATION=OFF \
  -DWITH_SWIFT=OFF \
  -DWITH_GRPC=OFF \
  -DBUILD_AWS_BACKUP=OFF \
  "-DOPENSSL_ROOT_DIR=${OPENSSL_PREFIX}" \
  -DOPENSSL_USE_STATIC_LIBS=TRUE

# ── 4. Fix toml11 + CMake 4.x incompatibility ──────────────────────────────────
# toml11 v3.4.0 uses cmake_minimum_required syntax removed in CMake 4.x.
TOML_CACHE="$BUILD_DIR/toml11Project-prefix/tmp/toml11Project-cache-Release.cmake"
TOML_STAMP="$BUILD_DIR/toml11Project-prefix/src/toml11Project-stamp/toml11Project-configure"

if [[ -f "$TOML_CACHE" ]] && ! grep -q "CMAKE_POLICY_VERSION_MINIMUM" "$TOML_CACHE"; then
  echo ""
  echo "==> Patching toml11 cmake cache for CMake 4.x compatibility..."
  sed -i '' '1a\
set(CMAKE_POLICY_VERSION_MINIMUM "3.5" CACHE STRING "Initial cache" FORCE)
' "$TOML_CACHE"
  rm -f "$TOML_STAMP"
  ninja toml11Project
fi

# ── 5. Build ───────────────────────────────────────────────────────────────────
echo ""
echo "==> Building fdbserver, fdbcli, fdbmonitor, fdb_c..."
echo "    (this takes ~45 minutes on Apple Silicon — boost compiles from source)"
ninja -j"$(sysctl -n hw.logicalcpu)" fdbserver fdbcli fdbmonitor fdb_c

# ── 6. Verify artifacts ────────────────────────────────────────────────────────
echo ""
echo "==> Verifying artifacts..."
for f in bin/fdbserver bin/fdbcli bin/fdbmonitor lib/libfdb_c.dylib; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: Missing artifact: $f"
    exit 1
  fi
  echo "  ✓ $f ($(du -sh "$f" | cut -f1))"
done

# ── 7. Stage release assets ────────────────────────────────────────────────────
echo ""
echo "==> Staging release assets..."
STAGING="$BUILD_DIR/release-assets"
mkdir -p "$STAGING"

cp bin/fdbserver      "$STAGING/fdbserver-${PLATFORM}"
cp bin/fdbcli         "$STAGING/fdbcli-${PLATFORM}"
cp bin/fdbmonitor     "$STAGING/fdbmonitor"
cp lib/libfdb_c.dylib "$STAGING/libfdb_c-${PLATFORM}.dylib"

# Headers from source tree
for h in fdb_c.h fdb_c_types.h; do
  src="$WORKDIR/bindings/c/foundationdb/$h"
  [[ -f "$src" ]] && cp "$src" "$STAGING/$h"
done

# Generated headers from build
for h in fdb_c_apiversion.g.h fdb_c_options.g.h; do
  found="$(find "$BUILD_DIR" -name "$h" 2>/dev/null | head -1)"
  [[ -n "$found" ]] && cp "$found" "$STAGING/$h" || echo "WARNING: $h not found"
done

echo ""
ls -lh "$STAGING/"

# ── 8. Publish GitHub release ──────────────────────────────────────────────────
echo ""
echo "==> Publishing release ${VERSION} to ${REPO}..."

if gh release view "$VERSION" -R "$REPO" &>/dev/null; then
  echo "    Release ${VERSION} already exists — deleting and recreating."
  gh release delete "$VERSION" -R "$REPO" --yes
fi

gh release create "$VERSION" \
  -R "$REPO" \
  --title "FoundationDB ${VERSION} - Native macOS ARM64" \
  --notes "Native macOS ARM64 (Apple Silicon) build of FoundationDB ${VERSION}.

## Artifacts
- \`fdbserver-darwin-arm64\` — FDB server process
- \`fdbcli-darwin-arm64\` — FDB CLI client
- \`fdbmonitor\` — FDB process monitor
- \`libfdb_c-darwin-arm64.dylib\` — C client library (for CGO)
- Headers: \`fdb_c.h\`, \`fdb_c_types.h\`, \`fdb_c_apiversion.g.h\`, \`fdb_c_options.g.h\`

## Linux
Use the [official FDB ${VERSION} release](https://github.com/apple/foundationdb/releases/tag/${VERSION}) — it already provides \`aarch64\` and \`amd64\` Linux binaries." \
  "$STAGING/"*

echo ""
echo "======================================================"
echo "  Done! Release published:"
gh release view "$VERSION" -R "$REPO" --json url | python3 -c "import json,sys; print('  ' + json.load(sys.stdin)['url'])"
echo "======================================================"
