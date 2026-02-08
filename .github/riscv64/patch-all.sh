#!/bin/bash
# patch-all.sh — Apply all riscv64 patches to the Etcher build system
# Called by the GitHub Actions workflow. Must be run from the repo root.
#
# Environment variables required:
#   ELECTRON_EXTRACT_DIR — path to extracted riscv64 Electron binary
#   ELECTRON_CACHE_DIR   — path to Electron zip cache directory

set -euo pipefail

info() { echo "[patch] $*"; }

# Reset source files to upstream before applying patches (idempotent re-runs)
git checkout -- forge.sidecar.ts forge.config.ts webpack.config.ts 2>/dev/null || true

# -------------------------------------------------------------------------
# 1. Replace forge.sidecar.ts with riscv64 version (shell wrapper, no pkg)
# -------------------------------------------------------------------------
info "Replacing forge.sidecar.ts with riscv64 version..."
cp .github/riscv64/forge.sidecar.ts forge.sidecar.ts

# -------------------------------------------------------------------------
# 2. Create .npmrc to prevent Electron download attempts
# -------------------------------------------------------------------------
info "Creating .npmrc..."
cat > .npmrc << 'EOF'
electron_mirror=https://github.com/nicehash/nicehash-electron-riscv64/releases/download/
ELECTRON_SKIP_BINARY_DOWNLOAD=1
EOF

# -------------------------------------------------------------------------
# 3. Patch Electron module to return riscv64 binary path
# -------------------------------------------------------------------------
info "Patching Electron module path..."
ELECTRON_INDEX="node_modules/electron/index.js"
if [ -f "$ELECTRON_INDEX" ]; then
    node -e "
        const fs = require('fs');
        const p = JSON.stringify(process.env.ELECTRON_OVERRIDE_DIST_PATH + '/electron');
        const content = '// Patched for riscv64 build\\n'
            + 'const path = require(\"path\");\\n'
            + 'const electronPath = ' + p + ';\\n'
            + 'module.exports = electronPath;\\n';
        fs.writeFileSync(process.argv[1], content);
    " "$ELECTRON_INDEX"

    if [ -f "node_modules/electron/dist/index.js" ]; then
        cp "$ELECTRON_INDEX" "node_modules/electron/dist/index.js"
    fi
    info "Electron module patched → $ELECTRON_EXTRACT_DIR/electron"
fi

# -------------------------------------------------------------------------
# 4. Patch webpack config — sha256 hash + asset/resource (no WASM)
# -------------------------------------------------------------------------
info "Patching webpack.config.ts..."
node -e "
const fs = require('fs');
let src = fs.readFileSync('webpack.config.ts', 'utf8');

if (!src.includes('hashFunction')) {
    src = src.replace(
        'export const rendererConfig: Configuration = {',
        'export const rendererConfig: Configuration = {\n\toutput: { hashFunction: \"sha256\" },'
    );
    src = src.replace(
        'export const mainConfig: Configuration = {',
        'export const mainConfig: Configuration = {\n\toutput: { hashFunction: \"sha256\" },'
    );
    console.log('  Added hashFunction: sha256');
}

if (src.includes(\"loader: 'file-loader'\")) {
    src = src.replace(\"loader: 'file-loader',\", \"type: 'asset/resource',\");
    console.log('  Replaced file-loader with asset/resource');
}

fs.writeFileSync('webpack.config.ts', src);
"

# -------------------------------------------------------------------------
# 5. Patch loader-utils WASM md4 — replace with Node crypto sha256
# -------------------------------------------------------------------------
info "Patching loader-utils md4..."
LOADER_UTILS_PATCH='// Patched for riscv64 --jitless build (WebAssembly unavailable)
const crypto = require("crypto");
const create = () => {
  const hash = crypto.createHash("sha256");
  const instance = {
    update: (data, encoding) => {
      if (typeof data === "string") {
        hash.update(data, encoding || "utf8");
      } else {
        hash.update(data);
      }
      return instance;
    },
    digest: (type) => hash.digest(type),
  };
  return instance;
};
module.exports = { create };'

find node_modules -path "*/loader-utils/lib/hash/md4.js" -type f 2>/dev/null | while read -r md4file; do
    echo "$LOADER_UTILS_PATCH" > "$md4file"
    info "  Patched: $md4file"
done

# -------------------------------------------------------------------------
# 6. Patch html-webpack-plugin — defuse undici WASM lazy getters
# -------------------------------------------------------------------------
info "Patching html-webpack-plugin..."
HWP_INDEX="node_modules/html-webpack-plugin/index.js"
if [ -f "$HWP_INDEX" ]; then
    node -e "
const fs = require('fs');
let src = fs.readFileSync(process.argv[1], 'utf8');

if (src.includes('_defuseLazyGetters')) {
  console.log('  Already patched, skipping');
  process.exit(0);
}

const defuseHelper = [
  '',
  '// [riscv64-patch] Defuse undici WASM lazy getters under --jitless',
  'let _lazyGettersDefused = false;',
  'function _defuseLazyGetters() {',
  '  if (_lazyGettersDefused) return;',
  '  _lazyGettersDefused = true;',
  '  if (typeof WebAssembly !== \"undefined\") return;',
  '  const globals = [\"FormData\", \"Headers\", \"Request\", \"Response\", \"fetch\",',
  '    \"AbortController\", \"AbortSignal\"];',
  '  for (const name of globals) {',
  '    const desc = Object.getOwnPropertyDescriptor(global, name);',
  '    if (desc && desc.get) {',
  '      Object.defineProperty(global, name, {',
  '        value: undefined, configurable: true, enumerable: false, writable: true',
  '      });',
  '    }',
  '  }',
  '}',
  '',
].join('\\n');

let patched = false;

if (src.includes('class HtmlWebpackPlugin')) {
  src = src.replace('class HtmlWebpackPlugin', defuseHelper + 'class HtmlWebpackPlugin');
  patched = true;
}

if (src.includes('evaluateCompilationResult')) {
  src = src.replace(
    /evaluateCompilationResult\\s*\\(([^)]+)\\)\\s*\\{/,
    'evaluateCompilationResult (\$1) {\\n    _defuseLazyGetters();'
  );
  patched = true;
}

if (patched) {
  fs.writeFileSync(process.argv[1], src);
  console.log('  html-webpack-plugin patched');
} else {
  console.log('  Warning: patterns not found');
}
" "$HWP_INDEX"
fi

# -------------------------------------------------------------------------
# 7. Patch @electron/packager — add riscv64 to recognized architectures
# -------------------------------------------------------------------------
info "Patching @electron/packager targets..."
TARGETS_JS="node_modules/@electron/packager/dist/targets.js"
if [ -f "$TARGETS_JS" ]; then
    node -e "
const fs = require('fs');
let src = fs.readFileSync(process.argv[1], 'utf8');
let changes = 0;

if (!src.includes(\"'riscv64'\")) {
    src = src.replace(
        \"'mips64el', 'universal'\",
        \"'mips64el', 'riscv64', 'universal'\"
    );
    changes++;
}

if (src.includes(\"linux: ['ia32'\") && !src.match(/linux:.*riscv64/)) {
    src = src.replace(
        \"linux: ['ia32', 'x64', 'armv7l', 'arm64', 'mips64el']\",
        \"linux: ['ia32', 'x64', 'armv7l', 'arm64', 'mips64el', 'riscv64']\"
    );
    changes++;
}

if (changes > 0) {
    fs.writeFileSync(process.argv[1], src);
    console.log('  @electron/packager patched (' + changes + ' changes)');
} else {
    console.log('  riscv64 already present');
}
" "$TARGETS_JS"
fi

# -------------------------------------------------------------------------
# 8. Patch forge.config.ts — add electronZipDir for riscv64 Electron zip
# -------------------------------------------------------------------------
info "Patching forge.config.ts..."
node -e "
const fs = require('fs');
let src = fs.readFileSync('forge.config.ts', 'utf8');

if (!src.includes('electronZipDir')) {
    src = src.replace(
        'packagerConfig: {',
        'packagerConfig: {\n\t\telectronZipDir: process.env.ELECTRON_CACHE_DIR || process.env.HOME + \"/.cache/electron\",'
    );
    console.log('  Added electronZipDir to packagerConfig');
}

fs.writeFileSync('forge.config.ts', src);
"

info "All patches applied successfully"
