// What a tab is about, for the tab title and the queue board:
// - topic: a "Konu: <topic>" line at the top of a tab's first reply (ask for it in your CLAUDE.md).
// - project: the Projeler/<name> folder the tab works in, from an optional project store
//   (SLOTH_PROJECT_STORE, default workspace/oturum-izi/projeler.json: the project the tab edited last), else a
//   "Bu `Projeler/X` ile ilgili" line in Claude's replies.
// Both are optional: without them the tab keeps Claude Code's generated title and shows no project.
const fs = require('fs');
const os = require('os');
const path = require('path');

const CC_HOME = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const STORE = process.env.SLOTH_PROJECT_STORE || path.join(CC_HOME, 'workspace', 'oturum-izi', 'projeler.json');
const PROJELER = path.join(CC_HOME, 'Projeler');
const TOPIC_RE = /^[*`\s]*Konu:?[*`\s]*(.+)$/m;
const PROJECT_RE = /Projeler\/([A-Za-z0-9._-]+)`?\s+ile ilgili/g;

function readHead(file, bytes) {
  const fd = fs.openSync(file, 'r');
  try {
    const buf = Buffer.alloc(Math.min(bytes, fs.fstatSync(fd).size));
    fs.readSync(fd, buf, 0, buf.length, 0);
    return buf.toString('utf8');
  } finally { fs.closeSync(fd); }
}

function textsOf(entry) {
  const c = entry && entry.type === 'assistant' && entry.message && entry.message.content;
  return Array.isArray(c) ? c.filter((p) => p.type === 'text' && p.text).map((p) => p.text) : [];
}

function assistantTexts(text) {
  const out = [];
  for (const line of text.split('\n')) {
    if (!line.includes('"type":"assistant"')) continue;
    try { out.push(...textsOf(JSON.parse(line))); } catch {}
  }
  return out;
}

// The first "Konu:" line of the session, cleaned of markdown.
function topicOf(transcript) {
  let text = '';
  try { text = readHead(transcript, 1024 * 1024); } catch { return ''; }
  if (!text.includes('Konu')) return '';
  for (const t of assistantTexts(text)) {
    const m = t.match(TOPIC_RE);
    if (m) return m[1].replace(/[*`]/g, '').trim().slice(0, 40);
  }
  return '';
}

// Lowercased key from the lock store -> the folder's real spelling ("hq" -> "HQ").
function folderName(key) {
  try {
    const hit = fs.readdirSync(PROJELER).find((d) => d.toLowerCase() === key);
    if (hit) return hit;
  } catch {}
  return key;
}

// entries: the parsed transcript lines the caller already has (the tail is enough).
function projectOf(sid, entries) {
  try {
    const db = JSON.parse(fs.readFileSync(STORE, 'utf8'));
    const root = (db.kok && db.kok[sid] && db.kok[sid].id) || sid;
    const edits = (db.degisen && db.degisen[root]) || {};
    let best = '', at = 0;
    for (const [key, t] of Object.entries(edits)) {
      const last = Math.max(Number(t.dosya) || 0, Number(t.pano) || 0);
      if (last > at) { at = last; best = key; }
    }
    if (best) return folderName(best);
  } catch {}
  let last = '';
  for (const e of entries || []) {
    for (const t of textsOf(e)) for (const m of t.matchAll(PROJECT_RE)) last = m[1];
  }
  return last;
}

// Where Claude Code keeps a session's transcript: projects/<cwd with every non-alphanumeric as "-">/<id>.jsonl
function transcriptFor(cwd, sid) {
  return path.join(CC_HOME, 'projects', String(cwd || '').replace(/[^A-Za-z0-9]/g, '-'), `${sid}.jsonl`);
}

module.exports = { topicOf, projectOf, transcriptFor };
