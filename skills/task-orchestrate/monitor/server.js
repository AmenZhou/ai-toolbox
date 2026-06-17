'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');

const PORT = 7842;
const CWD = process.cwd();
const DIR = __dirname;

// ── helpers ──────────────────────────────────────────────────────────────────

function readFileSafe(filePath) {
  try {
    return fs.readFileSync(filePath, 'utf8');
  } catch (_) {
    return null;
  }
}

function send(res, statusCode, data) {
  const body = JSON.stringify(data);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-cache',
  });
  res.end(body);
}

function sendFile(res, filePath) {
  const content = readFileSafe(filePath);
  if (content === null) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
    return;
  }
  const ext = path.extname(filePath).toLowerCase();
  const mime = ext === '.html' ? 'text/html' : 'text/plain';
  res.writeHead(200, { 'Content-Type': mime });
  res.end(content);
}

// ── parsers ───────────────────────────────────────────────────────────────────

/**
 * Parse the ## Task Registry markdown table from project.md.
 * Returns an array of row objects: { id, summary, mode, current_phase, status, last_activity }
 */
function parseRegistry(projectMdContent) {
  const rows = [];
  // Find the Task Registry section
  const sectionMatch = projectMdContent.match(/## Task Registry\n([\s\S]*?)(?:\n## |\n# |$)/);
  if (!sectionMatch) return rows;

  const lines = sectionMatch[1].split('\n');
  let headerParsed = false;
  let headers = [];

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('<!--') || trimmed.endsWith('-->')) continue;

    if (trimmed.startsWith('|')) {
      const cells = trimmed.split('|').map(c => c.trim()).filter((_, i, arr) => i > 0 && i < arr.length - 1);

      if (!headerParsed) {
        // First pipe row = header
        headers = cells.map(h => h.toLowerCase().replace(/\s+/g, '_'));
        headerParsed = true;
        continue;
      }

      // Separator row (---|---|...)
      if (cells.every(c => /^[-:]+$/.test(c))) continue;

      if (headers.length > 0 && cells.length >= headers.length) {
        const row = {};
        headers.forEach((h, i) => { row[h] = cells[i] || ''; });
        rows.push({
          id: row['id'] || '',
          summary: row['summary'] || '',
          mode: row['mode'] || '',
          current_phase: row['current_phase'] || '',
          status: row['status'] || '',
          last_activity: row['last_activity'] || '',
        });
      }
    }
  }
  return rows;
}

/**
 * Parse MANIFEST.md lines of form: YYYY-MM-DD | filename | summary | tag1, tag2
 */
function parseManifest(content) {
  const entries = [];
  const lineRe = /^(\d{4}-\d{2}-\d{2})\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*(.+)$/;
  for (const line of content.split('\n')) {
    const m = line.match(lineRe);
    if (m) {
      entries.push({
        date: m[1].trim(),
        filename: m[2].trim(),
        summary: m[3].trim(),
        tags: m[4].trim(),
      });
    }
  }
  return entries;
}

// ── route handlers ────────────────────────────────────────────────────────────

function handleTasks(res) {
  const projectMdPath = path.join(CWD, '.orchestrate', 'project.md');
  const content = readFileSafe(projectMdPath);

  if (!content) {
    return send(res, 200, { registry: [], tasks: {} });
  }

  const registry = parseRegistry(content);
  const tasks = {};

  for (const row of registry) {
    if (!row.id) continue;
    if (row.status !== 'complete') {
      const taskPath = path.join(CWD, '.orchestrate', 'tasks', `${row.id}.md`);
      const taskContent = readFileSafe(taskPath);
      if (taskContent !== null) {
        tasks[row.id] = taskContent;
      }
    }
  }

  send(res, 200, { registry, tasks });
}

function handleHistory(res) {
  const manifestPath = path.join(CWD, 'orchestrate-history', 'MANIFEST.md');
  const manifestContent = readFileSafe(manifestPath);

  if (!manifestContent) {
    return send(res, 200, { manifest: [], entries: {} });
  }

  const manifest = parseManifest(manifestContent);
  const entries = {};

  for (const entry of manifest) {
    if (!entry.filename) continue;
    const filePath = path.join(CWD, 'orchestrate-history', entry.filename);
    const fileContent = readFileSafe(filePath);
    if (fileContent !== null) {
      entries[entry.filename] = fileContent;
    }
  }

  send(res, 200, { manifest, entries });
}

function handleLogs(res, query) {
  const taskId = (query.id || '').trim();
  if (!taskId) {
    return send(res, 200, { files: [], logs: {} });
  }

  const logsDir = path.join(CWD, '.orchestrate', 'logs');
  let dirEntries;
  try {
    dirEntries = fs.readdirSync(logsDir);
  } catch (_) {
    return send(res, 200, { files: [], logs: {} });
  }

  const matchingFiles = dirEntries.filter(f => f.startsWith(taskId));
  const logs = {};

  for (const filename of matchingFiles) {
    const content = readFileSafe(path.join(logsDir, filename));
    if (content !== null) {
      logs[filename] = content;
    }
  }

  send(res, 200, { files: matchingFiles, logs });
}

// ── server ────────────────────────────────────────────────────────────────────

const server = http.createServer((req, res) => {
  const parsed = url.parse(req.url, true);
  const pathname = parsed.pathname;

  if (req.method !== 'GET') {
    res.writeHead(405, { 'Content-Type': 'text/plain' });
    res.end('Method Not Allowed');
    return;
  }

  if (pathname === '/') {
    sendFile(res, path.join(DIR, 'index.html'));
  } else if (pathname === '/api/tasks') {
    handleTasks(res);
  } else if (pathname === '/api/history') {
    handleHistory(res);
  } else if (pathname === '/api/logs') {
    handleLogs(res, parsed.query);
  } else {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`task-orchestrate monitor listening on http://127.0.0.1:${PORT}`);
  console.log(`Working directory: ${CWD}`);
});

server.on('error', (err) => {
  console.error('Server error:', err.message);
  process.exit(1);
});
