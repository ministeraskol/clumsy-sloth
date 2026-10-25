#!/usr/bin/env node
// UserPromptSubmit hook for Clumsy Sloth: puts the tab's queue number in front of its title,
// e.g. "4 · Sekmeler", so the number on the sloth's screen is also on the VS Code tab. The name is the tab's
// "Konu:" topic (hooks/tabinfo.js), else Claude Code's generated title; a hand-made /rename is kept.
// Uses the hook's sessionTitle output (same effect as /rename). Claude names a tab after its first
// reply, so the number shows from the second message on. Runs synchronously but only for a few ms.
const fs = require('fs');
const path = require('path');
const { numberFor, stripNumber } = require('./numbers');
const { topicOf } = require('./tabinfo');

const SLOTH_DIR = process.env.CLUMSY_SLOTH_DIR || path.join(__dirname, '..');
const DATA_DIR = path.join(SLOTH_DIR, 'data');

function readTail(file, bytes) {
  const size = fs.statSync(file).size;
  const start = Math.max(0, size - bytes);
  const fd = fs.openSync(file, 'r');
  const buf = Buffer.alloc(size - start);
  fs.readSync(fd, buf, 0, buf.length, start);
  fs.closeSync(fd);
  return buf.toString('utf8');
}

// Latest custom title (set by /rename or by this hook) and latest generated title.
function titles(transcript) {
  let custom = '', ai = '';
  let text = '';
  try { text = readTail(transcript, 4 * 1024 * 1024); } catch { return { custom, ai }; }
  for (const line of text.split('\n')) {
    if (!line.includes('-title"')) continue;
    try {
      const e = JSON.parse(line);
      if (e.type === 'custom-title' && e.customTitle) custom = e.customTitle;
      if (e.type === 'ai-title' && e.aiTitle) ai = e.aiTitle;
    } catch {}
  }
  return { custom, ai };
}

function main(input) {
  if (process.env.CLAUDE_CODE_ENTRYPOINT !== 'claude-vscode') return;
  const sid = String(input.session_id || '');
  if (!/^[0-9a-f-]{36}$/i.test(sid)) return;
  const n = numberFor(DATA_DIR, sid);
  const transcript = String(input.transcript_path || '');
  const { custom, ai } = titles(transcript);
  // A title without our "n · " prefix was set by hand (/rename) and wins; otherwise the tab's "Konu:" topic.
  const renamed = custom && !/^\d+\s*·\s*/.test(custom);
  const base = (renamed ? custom : topicOf(transcript) || stripNumber(custom || ai)).trim();
  if (!base) return;
  const wanted = `${n} · ${base}`;
  if (custom === wanted) return;
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'UserPromptSubmit', sessionTitle: wanted } }));
}

const chunks = [];
process.stdin.on('data', (c) => chunks.push(c));
process.stdin.on('end', () => {
  try { main(JSON.parse(Buffer.concat(chunks).toString('utf8').replace(/^﻿/, ''))); } catch {}
});
