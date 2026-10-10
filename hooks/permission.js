#!/usr/bin/env node
// PermissionRequest hook for Clumsy Sloth (panel.ps1).
// When the panel is running, the request is written to <sloth>/data/requests/<id>.json and the hook waits
// up to WAIT_MS for <sloth>/data/answers/<id>.json, which the panel writes when Allow / Deny / "answer in
// the tab" is clicked. No answer, "pass" or no panel -> no output, so Claude Code shows its own prompt.
// In the VS Code extension the tab shows its own prompt at the same time (the hook and the tab race, the
// first answer wins), so the hook may wait long. If the tab answers first, Claude Code kills this process;
// the request file carries our pid so the panel can drop the card as soon as the process is gone.
const fs = require('fs');
const path = require('path');

const DATA_DIR = path.join(process.env.CLUMSY_SLOTH_DIR || path.join(__dirname, '..'), 'data');
const REQ_DIR = path.join(DATA_DIR, 'requests');
const ANS_DIR = path.join(DATA_DIR, 'answers');
const ALIVE = path.join(DATA_DIR, 'panel.alive');
const STATE_DIR = path.join(DATA_DIR, 'sessions');
const WAIT_MS = Number(process.env.SLOTH_WAIT_MS || 590000);

function short(s, max) {
  s = String(s || '').replace(/\s+/g, ' ').trim();
  return s.length > max ? s.slice(0, max - 1).trimEnd() + '…' : s;
}

// One readable line for what the tool wants to do.
function describe(tool, input) {
  input = input || {};
  if (input.command) return input.command;
  if (input.file_path) return input.file_path;
  if (input.url) return input.url;
  if (input.action && input.coordinate) return `${input.action} @ ${input.coordinate.join(',')}`;
  if (input.action) return input.action;
  if (input.query) return input.query;
  const json = JSON.stringify(input);
  return json === '{}' ? tool : json;
}

function dbg(msg) {
  if (process.env.SLOTH_DEBUG) try { fs.appendFileSync(process.env.SLOTH_DEBUG, `${new Date().toISOString()} ${msg}\n`); } catch {}
}

function panelAlive() {
  try { return Date.now() - fs.statSync(ALIVE).mtimeMs < 6000; } catch { return false; }
}

function titleOf(sid) {
  try { return JSON.parse(fs.readFileSync(path.join(STATE_DIR, `${sid}.json`), 'utf8').replace(/^\uFEFF/, '')).title || ''; } catch { return ''; }
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

// The tab and this hook race; when the tab wins, Claude Code neither tells nor kills the hook.
// The transcript tells us instead: the tool's result (or its denial) is appended once the prompt is answered.
function readFrom(file, start) {
  const fd = fs.openSync(file, 'r');
  try {
    const len = fs.fstatSync(fd).size - start;
    if (len <= 0) return '';
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, start);
    return buf.toString('utf8');
  } finally { fs.closeSync(fd); }
}
function findToolUseId(transcript, tool, toolInput) {
  try {
    const size = fs.statSync(transcript).size;
    const lines = readFrom(transcript, Math.max(0, size - 2000000)).split('\n').reverse();
    const want = JSON.stringify(toolInput || {});
    for (const line of lines) {
      if (!line.includes('"tool_use"')) continue;
      let m; try { m = JSON.parse(line); } catch { continue; }
      for (const c of (m.message && Array.isArray(m.message.content) ? m.message.content : [])) {
        if (c.type === 'tool_use' && c.name === tool && JSON.stringify(c.input || {}) === want) return c.id;
      }
    }
  } catch {}
  return '';
}
// Answered in the tab? With a known tool_use id we wait for its result; without one, any new tool result counts.
function answeredInTab(transcript, startSize, toolUseId) {
  try {
    const added = readFrom(transcript, startSize);
    return toolUseId ? added.includes(`"tool_use_id":"${toolUseId}"`) : added.includes('"tool_result"');
  } catch { return false; }
}

async function main(input) {
  if (process.env.CLAUDE_CODE_ENTRYPOINT !== 'claude-vscode') return;
  if (!panelAlive()) return;
  // Bypass / dontAsk tabs never wait for an answer: Claude Code still calls this hook (seen for Chrome MCP
  // tools) but approves on its own, so a card would only be a ghost that nothing listens to.
  if (['bypassPermissions', 'dontAsk'].includes(input.permission_mode)) return;
  const sid = String(input.session_id || '');
  const id = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  fs.mkdirSync(REQ_DIR, { recursive: true });
  fs.mkdirSync(ANS_DIR, { recursive: true });
  const reqFile = path.join(REQ_DIR, `${id}.json`);
  const ansFile = path.join(ANS_DIR, `${id}.json`);
  const req = {
    id, sessionId: sid, title: titleOf(sid) || path.basename(input.cwd || '') || 'Claude',
    tool: String(input.tool_name || ''), detail: short(describe(input.tool_name, input.tool_input), 300),
    pid: process.pid, created: Date.now(), expires: Date.now() + WAIT_MS,
  };
  fs.writeFileSync(reqFile + '.tmp', JSON.stringify(req));
  fs.renameSync(reqFile + '.tmp', reqFile);

  const transcript = String(input.transcript_path || '');
  let startSize = 0;
  try { startSize = fs.statSync(transcript).size; } catch {}
  let toolUseId = transcript ? findToolUseId(transcript, input.tool_name, input.tool_input) : '';
  dbg(`req ${id} tool_use_id=${toolUseId || '-'}`);

  let answer = null;
  const end = Date.now() + WAIT_MS;
  let lastCheck = 0;
  while (Date.now() < end) {
    if (transcript && Date.now() - lastCheck >= 1000) {
      lastCheck = Date.now();
      // The assistant message may land in the transcript a moment after this hook starts.
      if (!toolUseId) toolUseId = findToolUseId(transcript, input.tool_name, input.tool_input);
      if (answeredInTab(transcript, startSize, toolUseId)) { dbg(`req ${id} answered in tab`); break; }
    }
    if (fs.existsSync(ansFile)) {
      try { answer = JSON.parse(fs.readFileSync(ansFile, 'utf8').replace(/^﻿/, '')); } catch { answer = null; }
      if (answer) break;
    }
    await sleep(200);
  }
  for (const f of [reqFile, ansFile]) { try { fs.unlinkSync(f); } catch {} }

  const behavior = answer && answer.behavior;
  if (behavior === 'allow') {
    process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: 'allow' } } }));
  } else if (behavior === 'deny') {
    process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PermissionRequest',
      decision: { behavior: 'deny', message: 'The user denied this from the desktop panel.' } } }));
  }
}

const chunks = [];
process.stdin.on('data', (c) => chunks.push(c));
process.stdin.on('end', async () => {
  try { await main(JSON.parse(Buffer.concat(chunks).toString('utf8').replace(/^﻿/, ''))); } catch {}
  process.exit(0);
});
