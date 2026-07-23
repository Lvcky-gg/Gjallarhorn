'use strict';

// postinstall.js — runs after `npm install gjallarhorn`. If Odin is present it
// compiles the CLI ahead of time; if not, it prints guidance and exits 0 (so the
// npm install itself never fails just because Odin isn't set up yet — the CLI
// retries the build on first run).

const fs = require('fs');
const { findOdin, buildCli, binPath, ODIN_INSTALL } = require('./common');

// Skip in CI/dev contexts where a global-ish build isn't wanted.
if (process.env.GJALLARHORN_SKIP_POSTINSTALL) process.exit(0);

const odin = findOdin();
if (!odin) {
	console.warn('');
	console.warn('  gjallarhorn: the Odin compiler was not found on your PATH.');
	console.warn('  Gjallarhorn needs Odin to build its CLI and the apps you scaffold.');
	console.warn('  Install it:  ' + ODIN_INSTALL);
	console.warn('  Then run:    npm rebuild gjallarhorn   (or just `gjallarhorn`, which retries)');
	console.warn('');
	process.exit(0); // don't hard-fail the install
}

if (fs.existsSync(binPath)) process.exit(0);

console.log('  gjallarhorn: compiling the CLI with Odin (' + odin + ') …');
if (!buildCli()) {
	console.warn('  gjallarhorn: build did not complete — it will be retried on first run.');
}
process.exit(0);
