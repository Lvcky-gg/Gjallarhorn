'use strict';

// common.js — shared helpers for the npm distribution of the gjallarhorn CLI.
// The npm package ships the Odin *source* (cli/ + gjallarhorn/); the CLI binary is
// compiled from it with the user's Odin compiler (on postinstall, or lazily on the
// first run). Odin is a system prerequisite — there is no Odin package on npm — so
// we detect it and guide the user rather than pretend to install it.

const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const isWin = process.platform === 'win32';

// Repo/package root: this file lives at <root>/packaging/npm/scripts/common.js
const pkgRoot = path.resolve(__dirname, '..', '..', '..');

// The framework package `gjallarhorn new` vendors into a scaffolded project.
const libDir = path.join(pkgRoot, 'gjallarhorn');

// The compiled CLI lands in a build dir that is git/npm-ignored (platform-specific,
// produced at install time — never shipped in the tarball).
const buildDir = path.join(pkgRoot, 'packaging', 'npm', 'build');
const binBase = path.join(buildDir, 'gjallarhorn'); // -out: base; Odin adds .exe on Windows
const binPath = binBase + (isWin ? '.exe' : '');

const ODIN_INSTALL = 'https://odin-lang.org/docs/install/';

// findOdin returns the Odin version string if `odin` is on PATH, else null.
function findOdin() {
	const r = spawnSync('odin', ['version'], { encoding: 'utf8' });
	if (r.status !== 0) return null;
	return (r.stdout || r.stderr || '').trim();
}

// buildCli compiles cli/ into binPath with the user's Odin. Returns true on success.
function buildCli() {
	fs.mkdirSync(buildDir, { recursive: true });
	const r = spawnSync(
		'odin',
		['build', path.join(pkgRoot, 'cli'), '-o:speed', `-out:${binBase}`],
		{ stdio: 'inherit', cwd: pkgRoot }
	);
	return r.status === 0 && fs.existsSync(binPath);
}

module.exports = { isWin, pkgRoot, libDir, buildDir, binPath, ODIN_INSTALL, findOdin, buildCli };
