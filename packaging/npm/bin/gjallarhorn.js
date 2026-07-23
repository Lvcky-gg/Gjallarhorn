#!/usr/bin/env node
'use strict';

// gjallarhorn.js — the npm `bin` shim. It ensures the CLI is compiled (building it
// on first run if postinstall couldn't), points `gjallarhorn new` at the vendored
// framework source via GJALLARHORN_LIB, then execs the native CLI with the user's
// arguments and forwards its exit status / signals.

const { spawnSync } = require('child_process');
const fs = require('fs');
const { findOdin, buildCli, binPath, libDir, ODIN_INSTALL } = require('../scripts/common');

function ensureBinary() {
	if (fs.existsSync(binPath)) return true;
	const odin = findOdin();
	if (!odin) {
		console.error('gjallarhorn: the CLI is not built yet and Odin is not on your PATH.');
		console.error('  Install Odin (' + ODIN_INSTALL + '), then run: npm rebuild gjallarhorn');
		return false;
	}
	console.error('gjallarhorn: building the CLI (first run) …');
	return buildCli();
}

if (!ensureBinary()) process.exit(1);

const args = process.argv.slice(2);

// `run` and `build` exec the Odin compiler themselves — fail early with a clear
// message rather than a confusing exec error deep inside the native binary.
if ((args[0] === 'run' || args[0] === 'build') && !findOdin()) {
	console.error('gjallarhorn ' + args[0] + ': needs the Odin compiler on PATH — ' + ODIN_INSTALL);
	process.exit(127);
}

// GJALLARHORN_LIB tells the CLI where the framework package is, so `gjallarhorn new`
// vendors it out of this npm package instead of hunting for a checkout.
const env = Object.assign({}, process.env, { GJALLARHORN_LIB: libDir });

const r = spawnSync(binPath, args, { stdio: 'inherit', env });
if (r.error) {
	console.error('gjallarhorn: failed to launch the CLI:', r.error.message);
	process.exit(1);
}
if (r.signal) {
	// Re-raise the signal so the parent shell sees the same termination.
	process.kill(process.pid, r.signal);
}
process.exit(r.status == null ? 1 : r.status);
