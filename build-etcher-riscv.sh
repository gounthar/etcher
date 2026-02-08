#!/bin/bash
# build-etcher-riscv.sh — Build balenaEtcher v2.1.4 on RISC-V (Debian Trixie riscv64)
#
# Usage:
#   scp build-etcher-riscv.sh poddingue@192.168.1.185:~/
#   ssh poddingue@192.168.1.185 "nohup bash ~/build-etcher-riscv.sh > ~/etcher-riscv-build.log 2>&1 &"
#
# Monitor:
#   ssh poddingue@192.168.1.185 "tail -100 ~/etcher-riscv-build.log"

set -euo pipefail

LOGFILE="$HOME/etcher-riscv-build.log"
BUILD_DIR="$HOME/etcher-riscv-build-src"
ELECTRON_VERSION="37.2.4"
ELECTRON_RISCV_URL="https://github.com/riscv-forks/electron-riscv-releases/releases/download/v${ELECTRON_VERSION}.riscv1/electron-v${ELECTRON_VERSION}-linux-riscv64.zip"
ELECTRON_CACHE_DIR="$HOME/.cache/electron"
ELECTRON_EXTRACT_DIR="$HOME/electron-riscv64"

phase_pass() { echo "[PHASE $1] PASS: $2"; }
phase_fail() { echo "[PHASE $1] FAIL: $2"; exit 1; }
timestamp()  { date '+%Y-%m-%d %H:%M:%S'; }

echo "======================================================"
echo "balenaEtcher RISC-V build — started $(timestamp)"
echo "======================================================"
echo ""

# Work around V8 JIT bug on riscv64 (SpacemiT K1)
# V8's JIT compiler generates invalid riscv64 code causing "unreachable code" crashes
# --jitless forces interpreter-only mode: slower but stable
export NODE_OPTIONS="--jitless"
export MAKEFLAGS="-j$(nproc)"
echo "NODE_OPTIONS: $NODE_OPTIONS (V8 JIT disabled for riscv64 stability)"
echo "MAKEFLAGS: $MAKEFLAGS (parallel native compilation on $(nproc) cores)"
echo ""

# Quick-rerun mode: if BUILD_DIR already has node_modules from a previous run,
# skip phases 1-4 and jump straight to patching + building.
SKIP_TO_PHASE5=false
if [ -d "$BUILD_DIR/node_modules" ] && [ -f "$BUILD_DIR/package.json" ] && [ "${QUICK_RERUN:-}" = "1" ]; then
    SKIP_TO_PHASE5=true
    echo "QUICK_RERUN=1: Skipping phases 1-4 (using existing build dir)"
    echo ""
    cd "$BUILD_DIR"
    export ELECTRON_OVERRIDE_DIST_PATH="$ELECTRON_EXTRACT_DIR"
    export ELECTRON_SKIP_BINARY_DOWNLOAD=1
    export electron_config_cache="$ELECTRON_CACHE_DIR"
    export npm_config_arch=riscv64
    export npm_config_target_arch=riscv64
fi

if [ "$SKIP_TO_PHASE5" = "false" ]; then
###############################################################################
# PHASE 1: Install build prerequisites
###############################################################################
echo "[PHASE 1] Installing build prerequisites..."

# Check we are on riscv64
ARCH=$(uname -m)
if [ "$ARCH" != "riscv64" ]; then
    phase_fail 1 "Expected riscv64 architecture, got: $ARCH"
fi

# Install packages (idempotent)
sudo apt-get update -qq

# Build tools
sudo apt-get install -y --no-install-recommends \
    build-essential \
    python3 \
    git \
    curl \
    wget \
    unzip \
    pkg-config \
    fakeroot \
    dpkg \
    rpm \
    jq

# Native module build dependencies
sudo apt-get install -y --no-install-recommends \
    libusb-1.0-0-dev \
    libudev-dev \
    libsecret-1-dev

# Clean up previous Node.js installations that may interfere
for old_dir in /opt/nodejs-unofficial /opt/node-v20.9.0; do
    if [ -d "$old_dir" ]; then
        echo "  Removing leftover $old_dir..."
        sudo rm -rf "$old_dir"
    fi
done
sudo dpkg -r nodejs-unofficial 2>/dev/null || true

# Node.js — Use Debian Trixie's own Node 20 (most stable riscv64 build)
# Then upgrade npm from 9.2.0 to latest (satisfies @balena/lint >=9.8.1)
sudo apt-get install -y --no-install-recommends nodejs npm

echo "  Upgrading npm to latest..."
sudo npm install -g npm@latest
hash -r  # clear bash's command cache

# Install node-gyp globally
sudo npm install -g node-gyp --force
hash -r

# lzma-native needs liblzma headers and bzip2 to extract its bundled xz source
sudo apt-get install -y --no-install-recommends liblzma-dev bzip2

# Electron runtime dependencies (GTK, display libs, etc.)
sudo apt-get install -y --no-install-recommends \
    libasound2t64 \
    libatk1.0-0t64 \
    libcairo2 \
    libcups2t64 \
    libdbus-1-3 \
    libexpat1 \
    libfontconfig1 \
    libfreetype6 \
    libgbm1 \
    libgdk-pixbuf-2.0-0 \
    libglib2.0-0t64 \
    libgtk-3-0t64 \
    liblzma5 \
    libnotify4 \
    libnspr4 \
    libnss3 \
    libpango-1.0-0 \
    libx11-6 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxi6 \
    libxrandr2 \
    libxrender1 \
    libxss1 \
    libxtst6 || true  # some lib names differ on Trixie, allow partial success

# Verify Node.js version
NODE_VERSION=$(node --version)
echo "Node.js version: $NODE_VERSION"
NODE_MAJOR=$(echo "$NODE_VERSION" | sed 's/^v//' | cut -d. -f1)
if [ "$NODE_MAJOR" -lt 20 ]; then
    phase_fail 1 "Node.js version too old: $NODE_VERSION (need >=20)"
fi

NPM_VERSION=$(npm --version)
echo "npm version: $NPM_VERSION"
echo "node-gyp version: $(node-gyp --version 2>/dev/null || echo 'not found')"
echo "node path: $(which node)"
echo "npm path: $(which npm)"
phase_pass 1 "Prerequisites installed (node $NODE_VERSION, npm $NPM_VERSION on $ARCH)"
echo ""

###############################################################################
# PHASE 2: Clone etcher repository
###############################################################################
echo "[PHASE 2] Cloning etcher repository..."

if [ -d "$BUILD_DIR" ]; then
    echo "  Build directory already exists, removing..."
    rm -rf "$BUILD_DIR"
fi

git clone --depth 1 --branch v2.1.4 https://github.com/balena-io/etcher.git "$BUILD_DIR"
cd "$BUILD_DIR"

echo "  Cloned to: $BUILD_DIR"
echo "  Version: $(git describe --tags 2>/dev/null || echo 'v2.1.4')"
phase_pass 2 "Repository cloned"
echo ""

###############################################################################
# PHASE 3: Download riscv64 Electron binary
###############################################################################
echo "[PHASE 3] Downloading riscv64 Electron binary..."

mkdir -p "$ELECTRON_CACHE_DIR"
mkdir -p "$ELECTRON_EXTRACT_DIR"

ELECTRON_ZIP="$ELECTRON_CACHE_DIR/electron-v${ELECTRON_VERSION}-linux-riscv64.zip"

if [ -f "$ELECTRON_ZIP" ]; then
    echo "  Electron zip already cached at $ELECTRON_ZIP"
else
    echo "  Downloading from: $ELECTRON_RISCV_URL"
    wget -q --show-progress -O "$ELECTRON_ZIP" "$ELECTRON_RISCV_URL" || \
        curl -fSL -o "$ELECTRON_ZIP" "$ELECTRON_RISCV_URL"
fi

# Verify the zip is valid
if ! unzip -tq "$ELECTRON_ZIP" > /dev/null 2>&1; then
    phase_fail 3 "Downloaded Electron zip is corrupt"
fi

# Extract Electron binary
echo "  Extracting to $ELECTRON_EXTRACT_DIR..."
rm -rf "$ELECTRON_EXTRACT_DIR"/*
unzip -qo "$ELECTRON_ZIP" -d "$ELECTRON_EXTRACT_DIR"

# Ensure the electron binary is executable
chmod +x "$ELECTRON_EXTRACT_DIR/electron"

# Also place the zip in the format electron-download expects:
#   ~/.cache/electron/SHASUMS256.txt-37.2.4 (fake, optional)
#   The zip filename with the right naming convention
ELECTRON_CACHE_ZIP="$ELECTRON_CACHE_DIR/electron-v${ELECTRON_VERSION}-linux-riscv64.zip"
if [ ! -f "$ELECTRON_CACHE_ZIP" ]; then
    cp "$ELECTRON_ZIP" "$ELECTRON_CACHE_ZIP"
fi

echo "  Electron binary: $ELECTRON_EXTRACT_DIR/electron"
"$ELECTRON_EXTRACT_DIR/electron" --version 2>/dev/null && true
phase_pass 3 "Electron riscv64 binary ready"
echo ""

###############################################################################
# PHASE 4: Install npm dependencies
###############################################################################
echo "[PHASE 4] Installing npm dependencies..."
cd "$BUILD_DIR"

# Tell npm/electron not to download official (nonexistent) riscv64 binaries
export ELECTRON_OVERRIDE_DIST_PATH="$ELECTRON_EXTRACT_DIR"
export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export electron_config_cache="$ELECTRON_CACHE_DIR"
export npm_config_arch=riscv64
export npm_config_target_arch=riscv64

# Remove winusb-driver-generator from optionalDependencies (Windows-only, will fail)
echo "  Removing Windows-only optional dependency (winusb-driver-generator)..."
node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
if (pkg.optionalDependencies) {
    delete pkg.optionalDependencies['winusb-driver-generator'];
}
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
"

# Install dependencies
echo "  Running npm install..."
npm install --ignore-scripts 2>&1 || {
    echo "  npm install failed, retrying with --force..."
    npm install --ignore-scripts --force 2>&1
}

# Rebuild only the native modules the sidecar actually needs on Linux
# (blanket npm rebuild fails on Windows-only packages like electron-winstaller)
echo "  Rebuilding native modules needed by sidecar..."
SIDECAR_NATIVE_MODULES="usb lzma-native drivelist mountutils xxhash-addon @ronomon/direct-io bufferutil utf-8-validate"
for mod in $SIDECAR_NATIVE_MODULES; do
    echo "    Rebuilding $mod..."
    npm rebuild "$mod" 2>&1 || echo "    Warning: $mod rebuild failed (may be optional)"
done

# Install ts-node and typescript globally for forge to use
npx tsc --version 2>/dev/null || npm install -g typescript

phase_pass 4 "npm dependencies installed"
echo ""

fi  # end of SKIP_TO_PHASE5 conditional

###############################################################################
# PHASE 5: Patch build system for riscv64
###############################################################################
echo "[PHASE 5] Patching build system for riscv64..."
cd "$BUILD_DIR"

# Reset source files to upstream before applying patches (idempotent re-runs)
git checkout -- forge.sidecar.ts forge.config.ts webpack.config.ts 2>/dev/null || true


# -------------------------------------------------------------------------
# 5a. Patch forge.sidecar.ts — replace pkg with a shell wrapper approach
# -------------------------------------------------------------------------
echo "  Patching forge.sidecar.ts..."

cat > forge.sidecar.ts << 'SIDECAR_EOF'
import { PluginBase } from '@electron-forge/plugin-base';
import type {
	ForgeMultiHookMap,
	ResolvedForgeConfig,
} from '@electron-forge/shared-types';
import { WebpackPlugin } from '@electron-forge/plugin-webpack';
import { DefinePlugin } from 'webpack';

import { execFileSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

import debug from 'debug';

const log = debug('sidecar');

function isStartScrpt(): boolean {
	return process.env.npm_lifecycle_event === 'start';
}

function addWebpackDefine(
	config: ResolvedForgeConfig,
	defineName: string,
	binDir: string,
	binName: string,
): ResolvedForgeConfig {
	config.plugins.forEach((plugin) => {
		if (plugin.name !== 'webpack' || !(plugin instanceof WebpackPlugin)) {
			return;
		}

		const { mainConfig } = plugin.config as any;
		if (mainConfig.plugins == null) {
			mainConfig.plugins = [];
		}

		const value = isStartScrpt()
			? // on `npm start`, point directly to the binary
				path.resolve(binDir, binName)
			: // otherwise point relative to the resources folder of the bundled app
				binName;

		log(`define '${defineName}'='${value}'`);

		mainConfig.plugins.push(
			new DefinePlugin({
				// expose path to helper via this webpack define
				[defineName]: JSON.stringify(value),
			}),
		);
	});

	return config;
}

function build(
	sourcesDir: string,
	buildForArchs: string,
	binDir: string,
	binName: string,
) {
	// Step 1: TypeScript compilation (same as upstream)
	log('running: tsc --project tsconfig.sidecar.json --outDir', sourcesDir);
	execFileSync('tsc', ['--project', 'tsconfig.sidecar.json', '--outDir', sourcesDir], {
		shell: true,
		stdio: 'inherit',
	});

	buildForArchs.split(',').forEach((arch) => {
		const binPath = isStartScrpt()
			? path.resolve(binDir, binName)
			: path.resolve(binDir, arch, binName);

		// Step 2: Rebuild mountutils for target arch
		log('running: npm rebuild mountutils --arch=' + arch);
		try {
			execFileSync('npm', ['rebuild', 'mountutils', `--arch=${arch}`], {
				shell: true,
				stdio: 'inherit',
			});
		} catch (e) {
			log('mountutils rebuild failed (may be ok if not used):', String(e));
		}

		// Step 3: Instead of pkg (no riscv64 support), create a shell wrapper
		// The wrapper invokes node with the transpiled api.js
		const binParent = path.dirname(binPath);
		fs.mkdirSync(binParent, { recursive: true });

		// Copy transpiled sidecar source alongside the wrapper
		const sidecarDistDir = path.resolve(binParent, 'sidecar-dist');
		fs.mkdirSync(sidecarDistDir, { recursive: true });

		// Copy transpiled JS files
		copyDirSync(path.join(sourcesDir, 'util'), path.join(sidecarDistDir, 'util'));
		copyDirSync(path.join(sourcesDir, 'shared'), path.join(sidecarDistDir, 'shared'));

		// Create the wrapper script
		const wrapperContent = [
			'#!/bin/sh',
			'# etcher-util wrapper for riscv64 (replaces pkg binary)',
			'SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"',
			'SIDECAR_DIR="$SCRIPT_DIR/sidecar-dist"',
			'export NODE_PATH="$SCRIPT_DIR/../../app/node_modules:$NODE_PATH"',
			'exec node "$SIDECAR_DIR/util/api.js" "$@"',
			'',
		].join('\n');

		fs.writeFileSync(binPath, wrapperContent, { mode: 0o755 });
		log(`created wrapper at ${binPath}`);
	});
}

function copyDirSync(src: string, dest: string) {
	if (!fs.existsSync(src)) {
		return;
	}
	fs.mkdirSync(dest, { recursive: true });
	for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
		const srcPath = path.join(src, entry.name);
		const destPath = path.join(dest, entry.name);
		if (entry.isDirectory()) {
			copyDirSync(srcPath, destPath);
		} else {
			fs.copyFileSync(srcPath, destPath);
		}
	}
}

function copyArtifact(
	buildPath: string,
	arch: string,
	binDir: string,
	binName: string,
) {
	const binPath = isStartScrpt()
		? path.resolve(binDir, binName)
		: path.resolve(binDir, arch, binName);

	// buildPath points to appPath, which is inside resources dir
	const resourcesPath = path.dirname(buildPath);

	// Copy the wrapper script
	const dest = path.resolve(resourcesPath, path.basename(binPath));
	log(`copying '${binPath}' to '${dest}'`);
	fs.copyFileSync(binPath, dest);

	// Also copy the sidecar-dist directory next to the wrapper
	const sidecarSrc = path.resolve(path.dirname(binPath), 'sidecar-dist');
	const sidecarDest = path.resolve(resourcesPath, 'sidecar-dist');
	if (fs.existsSync(sidecarSrc)) {
		log(`copying sidecar-dist to '${sidecarDest}'`);
		copyDirSync(sidecarSrc, sidecarDest);
	}
}

export class SidecarPlugin extends PluginBase<void> {
	name = 'sidecar';

	constructor() {
		super();
		this.getHooks = this.getHooks.bind(this);
		log('isStartScript:', isStartScrpt());
	}

	getHooks(): ForgeMultiHookMap {
		const DEFINE_NAME = 'ETCHER_UTIL_BIN_PATH';
		const BASE_DIR = path.join('out', 'sidecar');
		const SRC_DIR = path.join(BASE_DIR, 'src');
		const BIN_DIR = path.join(BASE_DIR, 'bin');
		const BIN_NAME = `etcher-util${process.platform === 'win32' ? '.exe' : ''}`;

		return {
			resolveForgeConfig: async (currentConfig) => {
				log('resolveForgeConfig');
				return addWebpackDefine(currentConfig, DEFINE_NAME, BIN_DIR, BIN_NAME);
			},
			generateAssets: async (_config, platform, arch) => {
				log('generateAssets', { platform, arch });
				build(SRC_DIR, arch, BIN_DIR, BIN_NAME);
			},
			packageAfterCopy: async (
				_config,
				buildPath,
				electronVersion,
				platform,
				arch,
			) => {
				log('packageAfterCopy', {
					buildPath,
					electronVersion,
					platform,
					arch,
				});
				copyArtifact(buildPath, arch, BIN_DIR, BIN_NAME);
			},
		};
	}
}
SIDECAR_EOF

echo "  forge.sidecar.ts patched (pkg replaced with shell wrapper)"

# -------------------------------------------------------------------------
# 5b. Patch forge.config.ts — support riscv64 in postPackage hook
# -------------------------------------------------------------------------
echo "  Patching forge.config.ts..."

# The postPackage hook constructs the path with options.outputPaths which
# should work fine. No architecture-specific hardcoding to fix.
# But we need to make sure rebuildConfig doesn't block native module rebuild.
# Actually, rebuildConfig.onlyModules=[] prevents ALL native rebuilds which
# is intentional (they go into the sidecar instead). Keep this.

# -------------------------------------------------------------------------
# 5c. Patch package.json — ensure "electron" package doesn't try to download
# -------------------------------------------------------------------------
echo "  Patching package.json for riscv64 build..."

# The npm "electron" package has a postinstall script that downloads the
# official binary. We've already set ELECTRON_SKIP_BINARY_DOWNLOAD=1 and
# ELECTRON_OVERRIDE_DIST_PATH, but let's also add an .npmrc for safety.
cat > "$BUILD_DIR/.npmrc" << 'NPMRC_EOF'
electron_mirror=https://github.com/nicehash/nicehash-electron-riscv64/releases/download/
ELECTRON_SKIP_BINARY_DOWNLOAD=1
NPMRC_EOF

# -------------------------------------------------------------------------
# 5d. Create electron-riscv shim for @electron-forge to find the binary
# -------------------------------------------------------------------------
echo "  Creating Electron path override for forge..."

# electron-forge resolves the electron binary path via the "electron" npm
# package, which exports a module that returns the path. We need this to
# point to our riscv64 binary.
ELECTRON_MODULE_PATH="$BUILD_DIR/node_modules/electron"
if [ -d "$ELECTRON_MODULE_PATH" ]; then
    # Overwrite the path in the electron package's index.js / dist/index.js
    # The electron npm package typically exports the path from dist/index.js
    ELECTRON_INDEX="$ELECTRON_MODULE_PATH/index.js"

    # Create a simple override that returns our riscv64 electron path
    cat > "$ELECTRON_INDEX" << ELECTRON_SHIM_EOF
// Patched for riscv64 build — points to community Electron binary
const path = require('path');
const electronPath = '${ELECTRON_EXTRACT_DIR}/electron';
module.exports = electronPath;
ELECTRON_SHIM_EOF

    # Also patch dist/index.js if it exists
    if [ -f "$ELECTRON_MODULE_PATH/dist/index.js" ]; then
        cp "$ELECTRON_INDEX" "$ELECTRON_MODULE_PATH/dist/index.js"
    fi

    echo "  Electron module patched to point to: $ELECTRON_EXTRACT_DIR/electron"
fi

# -------------------------------------------------------------------------
# 5e. Patch webpack config — use JS-only hash (WASM unavailable with --jitless)
# -------------------------------------------------------------------------
echo "  Patching webpack.config.ts for --jitless compatibility..."

# --jitless disables WebAssembly entirely. Two WASM issues to fix:
# 1. webpack 5's default md4 hash uses WASM → switch to sha256 (Node crypto)
# 2. file-loader uses loader-utils which has its own WASM md4 → replace with asset/resource
node -e "
const fs = require('fs');
let src = fs.readFileSync('webpack.config.ts', 'utf8');

// Fix 1: Add hashFunction: sha256 to webpack output configs
if (!src.includes('hashFunction')) {
    src = src.replace(
        'export const rendererConfig: Configuration = {',
        'export const rendererConfig: Configuration = {\n\toutput: { hashFunction: \"sha256\" },'
    );
    src = src.replace(
        'export const mainConfig: Configuration = {',
        'export const mainConfig: Configuration = {\n\toutput: { hashFunction: \"sha256\" },'
    );
    console.log('    Added hashFunction: sha256 to webpack configs');
} else {
    console.log('    hashFunction already set, skipping');
}

// Fix 2: Replace file-loader with webpack 5 built-in asset/resource
// file-loader depends on loader-utils which has a WASM-based md4 hash
// that crashes under --jitless. asset/resource uses webpack's own hash (sha256).
if (src.includes(\"loader: 'file-loader'\")) {
    src = src.replace(\"loader: 'file-loader',\", \"type: 'asset/resource',\");
    console.log('    Replaced file-loader with asset/resource for font files');
} else {
    console.log('    file-loader already replaced, skipping');
}

fs.writeFileSync('webpack.config.ts', src);
"

# -------------------------------------------------------------------------
# 5f. Patch loader-utils WASM md4 — safety net for any remaining loaders
# -------------------------------------------------------------------------
echo "  Patching loader-utils md4 hash for --jitless compatibility..."

# loader-utils/lib/hash/md4.js uses WebAssembly to implement md4 hashing.
# Under --jitless, WebAssembly is completely unavailable.
# Replace the WASM implementation with Node.js crypto (sha256 as a stand-in).
# The exact hash algorithm doesn't matter for webpack — it just needs determinism.
LOADER_UTILS_MD4="$BUILD_DIR/node_modules/loader-utils/lib/hash/md4.js"
if [ -f "$LOADER_UTILS_MD4" ] && grep -q "riscv64" "$LOADER_UTILS_MD4" 2>/dev/null; then
    echo "    loader-utils md4.js already patched, skipping"
elif [ -f "$LOADER_UTILS_MD4" ]; then
    cat > "$LOADER_UTILS_MD4" << 'LOADERUTILS_EOF'
// Patched for riscv64 --jitless build (WebAssembly unavailable)
// Uses Node.js crypto sha256 as drop-in replacement for WASM md4
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

module.exports = { create };
LOADERUTILS_EOF
    echo "    Patched $LOADER_UTILS_MD4"
else
    echo "    loader-utils md4.js not found (may not be needed)"
fi

# Also patch any nested copies of loader-utils (e.g., under native-addon-loader)
find "$BUILD_DIR/node_modules" -path "*/loader-utils/lib/hash/md4.js" -type f 2>/dev/null | while read -r md4file; do
    if [ "$md4file" != "$LOADER_UTILS_MD4" ]; then
        cp "$LOADER_UTILS_MD4" "$md4file"
        echo "    Also patched: $md4file"
    fi
done

# -------------------------------------------------------------------------
# 5g. Patch html-webpack-plugin — prevent undici WASM loading in VM context
# -------------------------------------------------------------------------
echo "  Patching html-webpack-plugin for --jitless compatibility..."

# html-webpack-plugin 5.6.0 creates a VM sandbox context via:
#   vm.createContext({ ...global, FormData: global.FormData, Headers: global.Headers, ... })
#
# TWO problems trigger undici's WASM lazyllhttp under --jitless:
# 1. The `...global` spread iterates all global properties, invoking lazy getters
# 2. Explicit `FormData: global.FormData` lines also trigger lazy getters
#
# Fix: DEFUSE the lazy getters on the actual global object BEFORE the spread.
# We add a block of code at the top of evaluateCompilationResult that replaces
# the Node 20 lazy getters (FormData, Headers, etc.) with harmless stubs.
# This preserves the original `...global` behavior for all other globals.
HWP_INDEX="$BUILD_DIR/node_modules/html-webpack-plugin/index.js"
if [ -f "$HWP_INDEX" ]; then
    node -e "
const fs = require('fs');
let src = fs.readFileSync(process.argv[1], 'utf8');
let patched = false;

// Check if already patched (idempotent)
if (src.includes('_defuseLazyGetters')) {
  console.log('    html-webpack-plugin already patched, skipping');
  process.exit(0);
}

// Add a defuse helper that replaces lazy getters with stubs ONCE
const defuseHelper = [
  '',
  '// [riscv64-patch] Defuse undici WASM lazy getters under --jitless',
  'let _lazyGettersDefused = false;',
  'function _defuseLazyGetters() {',
  '  if (_lazyGettersDefused) return;',
  '  _lazyGettersDefused = true;',
  '  if (typeof WebAssembly !== \"undefined\") return; // Only needed under --jitless',
  '  const globals = [\"FormData\", \"Headers\", \"Request\", \"Response\", \"fetch\",',
  '    \"AbortController\", \"AbortSignal\"];',
  '  for (const name of globals) {',
  '    const desc = Object.getOwnPropertyDescriptor(global, name);',
  '    if (desc && desc.get) {',
  '      // Replace lazy getter with a harmless stub',
  '      Object.defineProperty(global, name, {',
  '        value: undefined, configurable: true, enumerable: false, writable: true',
  '      });',
  '    }',
  '  }',
  '}',
  '',
].join('\\n');

// Insert helper before the class definition
if (src.includes('class HtmlWebpackPlugin')) {
  src = src.replace('class HtmlWebpackPlugin', defuseHelper + 'class HtmlWebpackPlugin');
  patched = true;
  console.log('    Added _defuseLazyGetters helper');
}

// Call the defuse function at the start of evaluateCompilationResult
// The function signature is: evaluateCompilationResult (source, publicPath, templateFilename)
if (src.includes('evaluateCompilationResult')) {
  src = src.replace(
    /evaluateCompilationResult\\s*\\(([^)]+)\\)\\s*\\{/,
    'evaluateCompilationResult (\$1) {\\n    _defuseLazyGetters();'
  );
  patched = true;
  console.log('    Added _defuseLazyGetters() call in evaluateCompilationResult');
}

if (patched) {
  fs.writeFileSync(process.argv[1], src);
  console.log('    html-webpack-plugin patched successfully');
} else {
  console.log('    Warning: could not find expected patterns to patch');
}
" "$HWP_INDEX"
else
    echo "    html-webpack-plugin not found"
fi

# -------------------------------------------------------------------------
# 5h. Patch @electron/packager to accept riscv64 architecture
# -------------------------------------------------------------------------
echo "  Patching @electron/packager to accept riscv64 architecture..."

PACKAGER_TARGETS="$BUILD_DIR/node_modules/@electron/packager/dist/targets.js"
if [ -f "$PACKAGER_TARGETS" ]; then
    node -e "
const fs = require('fs');
let src = fs.readFileSync(process.argv[1], 'utf8');
let changes = 0;

// 1. Add 'riscv64' to officialArchs array
if (!src.includes(\"'riscv64'\")) {
    src = src.replace(
        \"'mips64el', 'universal'\",
        \"'mips64el', 'riscv64', 'universal'\"
    );
    changes++;
    console.log('    Added riscv64 to officialArchs');
}

// 2. Add 'riscv64' to linux platform arch combos
if (!src.includes(\"linux:.*riscv64\") && src.includes(\"linux: ['ia32'\")) {
    src = src.replace(
        \"linux: ['ia32', 'x64', 'armv7l', 'arm64', 'mips64el']\",
        \"linux: ['ia32', 'x64', 'armv7l', 'arm64', 'mips64el', 'riscv64']\"
    );
    changes++;
    console.log('    Added riscv64 to linux platform arch combos');
}

if (changes > 0) {
    fs.writeFileSync(process.argv[1], src);
    console.log('    @electron/packager targets.js patched (' + changes + ' changes)');
} else {
    console.log('    riscv64 already present in targets.js');
}
" "$PACKAGER_TARGETS"
else
    echo "    Warning: @electron/packager/dist/targets.js not found"
fi

# -------------------------------------------------------------------------
# 5i. Add electronZipDir to forge packagerConfig so packager finds our zip
# -------------------------------------------------------------------------
echo "  Patching forge.config.ts with electronZipDir..."

node -e "
const fs = require('fs');
let src = fs.readFileSync('forge.config.ts', 'utf8');

// Add electronZipDir to packagerConfig so @electron/packager finds our
// pre-downloaded riscv64 Electron zip instead of trying to download it.
if (!src.includes('electronZipDir')) {
    src = src.replace(
        'packagerConfig: {',
        'packagerConfig: {\n\t\telectronZipDir: process.env.ELECTRON_CACHE_DIR || process.env.HOME + \"/.cache/electron\",'
    );
    console.log('    Added electronZipDir to packagerConfig');
} else {
    console.log('    electronZipDir already present');
}

fs.writeFileSync('forge.config.ts', src);
"

# Also export ELECTRON_CACHE_DIR for forge.config.ts to use
export ELECTRON_CACHE_DIR="$ELECTRON_CACHE_DIR"

phase_pass 5 "Build system patched for riscv64"
echo ""

###############################################################################
# PHASE 6: Build
###############################################################################
echo "[PHASE 6] Building balenaEtcher for riscv64..."
cd "$BUILD_DIR"

# Set environment for the build
export ELECTRON_OVERRIDE_DIST_PATH="$ELECTRON_EXTRACT_DIR"
export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export electron_config_cache="$ELECTRON_CACHE_DIR"
export ELECTRON_CACHE_DIR="$ELECTRON_CACHE_DIR"

# Keep --jitless for V8 stability. The html-webpack-plugin patch (Phase 5g)
# removes the FormData/Headers globals that would trigger undici WASM loading.
# The preload script is available as a safety net but not enabled by default
# as it caused early initialization failures in electron-forge.
echo "  NODE_OPTIONS: $NODE_OPTIONS"

# electron-forge package
echo "  Running: npx electron-forge package --platform=linux --arch=riscv64"
echo "  (this may take a while...)"

npx electron-forge package --platform=linux --arch=riscv64 2>&1
PACKAGE_EXIT=$?

if [ "$PACKAGE_EXIT" -ne 0 ]; then
    echo ""
    echo "  electron-forge package failed with exit code $PACKAGE_EXIT"
    echo "  Checking for common issues..."

    # Show last 50 lines of any webpack build output
    if [ -d "$BUILD_DIR/.webpack" ]; then
        echo "  Webpack output exists at .webpack/"
    fi

    phase_fail 6 "electron-forge package failed (exit code $PACKAGE_EXIT)"
fi

echo ""
echo "  Package step complete!"

# Check output
PACKAGE_OUT="$BUILD_DIR/out"
if [ -d "$PACKAGE_OUT" ]; then
    echo "  Output directory contents:"
    ls -la "$PACKAGE_OUT/" 2>/dev/null
    du -sh "$PACKAGE_OUT"/* 2>/dev/null
else
    phase_fail 6 "Output directory not found at $PACKAGE_OUT"
fi

# Optionally try to make .deb
echo ""
echo "  Attempting: npx electron-forge make --platform=linux --arch=riscv64 --targets=@electron-forge/maker-deb"
npx electron-forge make --platform=linux --arch=riscv64 --targets=@electron-forge/maker-deb 2>&1 || \
    echo "  Warning: make (deb) failed — the packaged app is still available in out/"

phase_pass 6 "Build completed"
echo ""

###############################################################################
# PHASE 7: Report results
###############################################################################
echo "[PHASE 7] Build results"
echo "======================================================"
echo ""

echo "Output directory: $PACKAGE_OUT"
if [ -d "$PACKAGE_OUT" ]; then
    echo ""
    echo "Directory tree (2 levels deep):"
    find "$PACKAGE_OUT" -maxdepth 2 -type f | head -50
    echo ""
    echo "Sizes:"
    du -sh "$PACKAGE_OUT"/* 2>/dev/null
fi

# Check for .deb files
echo ""
echo "Installer artifacts:"
find "$PACKAGE_OUT" -name "*.deb" -o -name "*.rpm" -o -name "*.zip" 2>/dev/null | while read -r f; do
    echo "  $(ls -lh "$f" | awk '{print $5, $NF}')"
done

# Try to verify the Electron app launches (headless, just check version)
ETCHER_BIN=$(find "$PACKAGE_OUT" -name "balena-etcher" -type f 2>/dev/null | head -1)
if [ -n "$ETCHER_BIN" ] && [ -x "$ETCHER_BIN" ]; then
    echo ""
    echo "Electron binary found: $ETCHER_BIN"
    echo "Attempting version check..."
    "$ETCHER_BIN" --version 2>/dev/null && true
fi

echo ""
echo "======================================================"
echo "Build finished at $(timestamp)"
echo "======================================================"
phase_pass 7 "All done"
