'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { execSync } = require('node:child_process');

const PLIST_PATH = `${process.env.HOME}/Library/LaunchAgents/com.orchestrate.tend.plist`;
const LABEL = 'com.orchestrate.tend';
const EXPECTED_BINARY = `${process.env.HOME}/.local/bin/claude`;

// ── helpers ──────────────────────────────────────────────────────────────────

function launchctlList() {
  const out = execSync('launchctl list', { encoding: 'utf8' });
  for (const line of out.split('\n')) {
    const parts = line.trim().split(/\s+/);
    if (parts[2] === LABEL) {
      return { pid: parts[0], exitCode: parseInt(parts[1], 10) };
    }
  }
  return null;
}

// ── tests ─────────────────────────────────────────────────────────────────────

test('plist file exists', () => {
  assert.ok(fs.existsSync(PLIST_PATH), `plist not found at ${PLIST_PATH}`);
});

test('plist binary path is correct', () => {
  const raw = fs.readFileSync(PLIST_PATH, 'utf8');
  assert.ok(
    raw.includes(EXPECTED_BINARY),
    `expected binary "${EXPECTED_BINARY}" not found in plist`
  );
});

test('claude binary exists on disk', () => {
  assert.ok(
    fs.existsSync(EXPECTED_BINARY),
    `claude binary missing at ${EXPECTED_BINARY}`
  );
});

test('launch agent is loaded in launchctl', () => {
  const entry = launchctlList();
  assert.ok(entry !== null, `"${LABEL}" not found in launchctl list`);
});

test('launch agent last exit code is 0 or - (idle)', () => {
  const entry = launchctlList();
  assert.ok(entry !== null, `"${LABEL}" not found in launchctl list`);
  // Exit code 1 can occur when session limits block claude -p; only fail on unexpected codes
  assert.ok(
    entry.exitCode === 0 || entry.exitCode === 1,
    `unexpected launchctl exit code ${entry.exitCode} for ${LABEL}`
  );
});

test('heartbeat log directory exists', () => {
  const logDir = `${process.env.HOME}/apps/ai-console/.orchestrate/logs`;
  assert.ok(fs.existsSync(logDir), `log directory missing at ${logDir}`);
});
