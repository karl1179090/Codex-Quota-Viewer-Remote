#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${SESSION_MANAGER_VENDOR_DIR:-$ROOT_DIR/Vendor/CodexMM}"
STAGING_DIR="${SESSION_MANAGER_STAGING_DIR:-$ROOT_DIR/.build/session-manager}"
OUTPUT_DIR="${1:-}"

if [[ -z "$OUTPUT_DIR" ]]; then
  echo "usage: $0 <session-manager-output-dir>" >&2
  exit 1
fi

if [[ ! -d "$VENDOR_DIR" ]]; then
  echo "error: vendored CodexMM directory not found: $VENDOR_DIR" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "error: node is required to build the bundled session manager." >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "error: npm is required to build the bundled session manager." >&2
  exit 1
fi

NODE_BIN="$(node -p 'process.execPath')"
STAGING_SOURCE_DIR="$STAGING_DIR/source"
APP_OUTPUT_DIR="$OUTPUT_DIR/App"
RUNTIME_OUTPUT_DIR="$OUTPUT_DIR/Runtime"

copy_node_runtime_libraries() {
  local node_bin="$1"
  local runtime_dir="$2"

  if ! command -v otool >/dev/null 2>&1; then
    return
  fi

  local libnode_ref
  libnode_ref="$(otool -L "$node_bin" | awk '/@rpath\/libnode\..*\.dylib/ { print $1; exit }')"
  if [[ -z "$libnode_ref" ]]; then
    return
  fi

  local libnode_name
  libnode_name="$(basename "$libnode_ref")"

  local node_prefix
  node_prefix="$(cd "$(dirname "$node_bin")/.." && pwd)"

  local candidates=(
    "$node_prefix/lib/$libnode_name"
    "/opt/homebrew/lib/$libnode_name"
    "/usr/local/lib/$libnode_name"
  )

  if command -v brew >/dev/null 2>&1; then
    local brew_prefix
    brew_prefix="$(brew --prefix 2>/dev/null || true)"
    if [[ -n "$brew_prefix" ]]; then
      candidates+=("$brew_prefix/lib/$libnode_name")
    fi
  fi

  local libnode_source=""
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      libnode_source="$candidate"
      break
    fi
  done

  if [[ -z "$libnode_source" ]]; then
    echo "error: $node_bin depends on $libnode_ref, but $libnode_name was not found." >&2
    echo "       searched: ${candidates[*]}" >&2
    exit 1
  fi

  mkdir -p "$runtime_dir/lib"
  cp "$libnode_source" "$runtime_dir/lib/$libnode_name"
  chmod 0644 "$runtime_dir/lib/$libnode_name"
}

rm -rf "$STAGING_DIR" "$OUTPUT_DIR"
mkdir -p "$STAGING_SOURCE_DIR" "$APP_OUTPUT_DIR" "$RUNTIME_OUTPUT_DIR/bin"

rsync -a \
  --delete \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude 'dist' \
  --exclude '.DS_Store' \
  "$VENDOR_DIR"/ "$STAGING_SOURCE_DIR"/

cd "$STAGING_SOURCE_DIR"
npm ci
npm run build
npm prune --omit=dev

mkdir -p "$APP_OUTPUT_DIR/dist" "$APP_OUTPUT_DIR/node_modules"
rsync -a --delete dist/ "$APP_OUTPUT_DIR/dist/"
rsync -a --delete node_modules/ "$APP_OUTPUT_DIR/node_modules/"
cp package.json "$APP_OUTPUT_DIR/package.json"
cp package-lock.json "$APP_OUTPUT_DIR/package-lock.json"
cp "$NODE_BIN" "$RUNTIME_OUTPUT_DIR/bin/node"
chmod 0755 "$RUNTIME_OUTPUT_DIR/bin/node"
copy_node_runtime_libraries "$NODE_BIN" "$RUNTIME_OUTPUT_DIR"

echo "Bundled session manager prepared at: $OUTPUT_DIR"
