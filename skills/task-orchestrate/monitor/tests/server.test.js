'use strict';

const { test, before, after, describe } = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');

const TEST_PORT = 7843;
let tmpDir;
let serverProcess;

function get(pathname) {
  return new Promise((resolve, reject) => {
    http.get(`http://127.0.0.1:${TEST_PORT}${pathname}`, (res) => {
      let body = '';
      res.on('data', c => body += c);
      res.on('end', () => {
        const ct = res.headers['content-type'] || '';
        if (ct.includes('application/json')) {
          try { resolve({ status: res.statusCode, body: JSON.parse(body) }); }
          catch (_) { resolve({ status: res.statusCode, body }); }
        } else {
          resolve({ status: res.statusCode, body });
        }
      });
    }).on('error', reject);
  });
}

before(async () => {
  // Fixture: minimal .orchestrate layout
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitor-test-'));
  const orch = path.join(tmpDir, '.orchestrate');
  fs.mkdirSync(path.join(orch, 'tasks'), { recursive: true });
  fs.mkdirSync(path.join(orch, 'logs'), { recursive: true });
  fs.mkdirSync(path.join(orch, 'inbox', 'processed'), { recursive: true });

  fs.writeFileSync(path.join(orch, 'project.md'), [
    '# Orchestrate — test',
    '',
    '## Task Registry',
    '| ID | summary | mode | current_phase | status | last_activity |',
    '|----|---------|------|---------------|--------|---------------|',
    '| test-001 | test task | auto | 1 | running | 2026-01-01T00:00:00Z |',
  ].join('\n'));

  fs.writeFileSync(path.join(orch, 'tasks', 'test-001.md'), '# Task test-001\nphase 1 details');

  fs.writeFileSync(path.join(orch, 'logs', 'heartbeat.log'),
    '[2026-01-01T00:00:00Z] tend — idle\n' +
    '[2026-01-01T00:05:00Z] inbox-analyzer — scanned 2 logs, found 0 issues\n',
  );

  fs.writeFileSync(path.join(orch, 'inbox', 'pending-job.md'),
    '# Pending Job\n\n## Goal\nFix the thing.\n',
  );

  // Start server in tmpDir with TEST_PORT
  serverProcess = spawn(process.execPath, [
    path.join(__dirname, '..', 'server.js'),
  ], {
    cwd: tmpDir,
    env: { ...process.env, PORT: String(TEST_PORT) },
    stdio: 'pipe',
  });

  // Wait for server to be ready
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('server start timeout')), 5000);
    serverProcess.stdout.on('data', (chunk) => {
      if (chunk.toString().includes('listening')) {
        clearTimeout(timeout);
        resolve();
      }
    });
    serverProcess.on('error', (err) => { clearTimeout(timeout); reject(err); });
  });
});

after(() => {
  if (serverProcess) serverProcess.kill();
  if (tmpDir) fs.rmSync(tmpDir, { recursive: true, force: true });
});

test('/ serves index.html', async () => {
  const { status, body } = await get('/');
  assert.equal(status, 200);
  assert.ok(typeof body === 'string' && body.includes('task-orchestrate monitor'),
    'index.html should contain page title');
});

test('/api/tasks returns registry rows and task content', async () => {
  const { status, body } = await get('/api/tasks');
  assert.equal(status, 200);
  assert.ok(Array.isArray(body.registry));
  assert.equal(body.registry.length, 1);
  assert.equal(body.registry[0].id, 'test-001');
  assert.equal(body.registry[0].status, 'running');
  assert.ok(body.tasks['test-001'].includes('phase 1 details'));
});

test('/api/inbox returns pending inbox files excluding processed/', async () => {
  const { status, body } = await get('/api/inbox');
  assert.equal(status, 200);
  assert.ok(Array.isArray(body.items));
  assert.equal(body.items.length, 1);
  assert.equal(body.items[0].filename, 'pending-job.md');
  assert.equal(body.items[0].title, 'Pending Job');
});

test('/api/heartbeat returns log lines', async () => {
  const { status, body } = await get('/api/heartbeat');
  assert.equal(status, 200);
  assert.ok(Array.isArray(body.lines));
  assert.ok(body.lines.some(l => l.includes('inbox-analyzer')));
});

test('unknown route returns 404', async () => {
  const { status } = await get('/api/no-such-route');
  assert.equal(status, 404);
});
