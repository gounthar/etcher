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
			? path.resolve(binDir, binName)
			: binName;

		log(`define '${defineName}'='${value}'`);

		mainConfig.plugins.push(
			new DefinePlugin({
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
	log('running: tsc --project tsconfig.sidecar.json --outDir', sourcesDir);
	execFileSync('tsc', ['--project', 'tsconfig.sidecar.json', '--outDir', sourcesDir], {
		stdio: 'inherit',
	});

	buildForArchs.split(',').forEach((arch) => {
		const binPath = isStartScrpt()
			? path.resolve(binDir, binName)
			: path.resolve(binDir, arch, binName);

		log('running: npm rebuild mountutils --arch=' + arch);
		try {
			execFileSync('npm', ['rebuild', 'mountutils', `--arch=${arch}`], {
				stdio: 'inherit',
			});
		} catch (e) {
			log('mountutils rebuild failed (may be ok if not used):', String(e));
		}

		const binParent = path.dirname(binPath);
		fs.mkdirSync(binParent, { recursive: true });

		const sidecarDistDir = path.resolve(binParent, 'sidecar-dist');
		fs.mkdirSync(sidecarDistDir, { recursive: true });

		copyDirSync(path.join(sourcesDir, 'util'), path.join(sidecarDistDir, 'util'));
		copyDirSync(path.join(sourcesDir, 'shared'), path.join(sidecarDistDir, 'shared'));

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

	const resourcesPath = path.dirname(buildPath);

	const dest = path.resolve(resourcesPath, path.basename(binPath));
	log(`copying '${binPath}' to '${dest}'`);
	fs.copyFileSync(binPath, dest);

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
