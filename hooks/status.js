#!/usr/bin/env node
// Tab status hook for Clumsy Sloth: writes one state file per VS Code Claude Code session to
// <sloth>/data/sessions/<session>.json, which panel.ps1 reads. Runs async on UserPromptSubmit, Stop,
// PreToolUse (AskUserQuestion), PostToolUse, Notification and SessionEnd.
// Statuses: working | done | waiting | question | permission.
// "waiting" = the last reply contains the askMarker regex from config.json (optional), e.g. "Your turn:".
const fs = require('fs');
const path = require('path');

const SLOTH_DIR = process.env.CLUMSY_SLOTH_DIR || path.join(__dirname, '..');
const STATE_DIR = path.join(SLOTH_DIR, 'data', 'sessions');
const TAIL_BYTES = 2 * 1024 * 1024;

function askMarker() {
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(SLOTH_DIR, 'config.json'), 'utf8').replace(/^﻿/, ''));
    return cfg.askMarker ? new RegExp(cfg.askMarker, 'i') : null;
  } catch { return null; }
}

function readTail(file, bytes) {
  const size = fs.statSync(file).size;
  const start = Math.max(0, size - bytes);
  const fd = fs.openSync(file, 'r');
  const buf = Buffer.alloc(size - start);
  fs.readSync(fd, buf, 0, buf.length, start);
  fs.closeSync(fd);
  const text = buf.toString('utf8');
  return start > 0 ? text.slice(text.indexOf('\n') + 1) : text;
}

function parseLines(text) {
  const out = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try { out.push(JSON.parse(line)); } catch {}
  }
  return out;
}

// A renamed tab (custom-title) wins over the generated one (ai-title).
function tabTitle(entries) {
  let ai = '', custom = '';
  for (const e of entries) {
    if (e.type === 'custom-title' && e.customTitle) custom = e.customTitle;
    if (e.type === 'ai-title' && e.aiTitle) ai = e.aiTitle;
  }
  return custom || ai;
}

function titleOf(transcript, entries) {
  let title = tabTitle(entries);
  if (!title && transcript && fs.existsSync(transcript)) {
    title = tabTitle(parseLines(fs.readFileSync(transcript, 'utf8')));
  }
  return title;
}

function lastAssistantText(entries) {
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i];
    if (e.type !== 'assistant' || !e.message || !Array.isArray(e.message.content)) continue;
    const text = e.message.content.filter((c) => c.type === 'text').map((c) => c.text).join('\n').trim();
    if (text) return text;
  }
  return '';
}

function plain(s) {
  return String(s || '')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/[*_`#>]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function short(s, max) {
  s = plain(s);
  return s.length > max ? s.slice(0, max - 1).trimEnd() + '…' : s;
}

function firstSentence(s) {
  const p = plain(s);
  const m = p.match(/^.{20,}?[.!?](\s|$)/);
  return m ? m[0].trim() : p;
}

function writeState(sid, fields) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  const file = path.join(STATE_DIR, `${sid}.json`);
  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(file, 'utf8')); } catch {}
  const next = Object.assign({ sessionId: sid }, prev, { updated: Date.now() }, fields);
  if (!next.title) next.title = 'Claude';
  fs.writeFileSync(file + '.tmp', JSON.stringify(next));
  fs.renameSync(file + '.tmp', file);
}

function stopOutcome(text) {
  const marker = askMarker();
  const parts = marker ? text.split(marker) : [text];
  if (parts.length > 1) return { status: 'waiting', detail: short(parts[parts.length - 1], 180) };
  return { status: 'done', detail: short(firstSentence(text), 160) };
}

function main(input) {
  // Only VS Code tabs: headless `claude -p` runs and scripts stay silent.
  if (process.env.CLAUDE_CODE_ENTRYPOINT !== 'claude-vscode') return;
  const sid = String(input.session_id || '');
  if (!/^[0-9a-f-]{36}$/i.test(sid)) return;
  const event = input.hook_event_name;

  if (event === 'SessionEnd') {
    try { fs.unlinkSync(path.join(STATE_DIR, `${sid}.json`)); } catch {}
    return;
  }

  // A tool ran: whatever the tab was asking for got answered, so it is working again.
  if (event === 'PostToolUse') {
    let cur = {};
    try { cur = JSON.parse(fs.readFileSync(path.join(STATE_DIR, `${sid}.json`), 'utf8')); } catch { return; }
    if (cur.status === 'permission' || cur.status === 'question') writeState(sid, { status: 'working' });
    return;
  }

  let entries = [];
  if (input.transcript_path && fs.existsSync(input.transcript_path)) {
    entries = parseLines(readTail(input.transcript_path, TAIL_BYTES));
  }
  const title = titleOf(input.transcript_path, entries);
  const base = title ? { title } : {};

  if (event === 'UserPromptSubmit') {
    writeState(sid, Object.assign(base, { status: 'working', detail: short(input.prompt, 120) }));
  } else if (event === 'Stop') {
    if (input.stop_hook_active) return;
    writeState(sid, Object.assign(base, stopOutcome(input.last_assistant_message || lastAssistantText(entries))));
  } else if (event === 'PreToolUse' && input.tool_name === 'AskUserQuestion') {
    const q = input.tool_input && Array.isArray(input.tool_input.questions) && input.tool_input.questions[0];
    writeState(sid, Object.assign(base, { status: 'question', detail: short(q && q.question, 180) }));
  } else if (event === 'Notification' && /permission/i.test(String(input.notification_type || input.message || ''))) {
    writeState(sid, Object.assign(base, { status: 'permission', detail: short(input.message, 180) }));
  }
}

const chunks = [];
process.stdin.on('data', (c) => chunks.push(c));
process.stdin.on('end', () => {
  try { main(JSON.parse(Buffer.concat(chunks).toString('utf8').replace(/^﻿/, ''))); } catch {}
});
