// Queue numbers for Clumsy Sloth, like the ticket numbers on a hospital screen.
// A number belongs to a Claude Code process (one VS Code tab), so it survives /clear. Numbers of closed
// tabs are freed and the smallest free number goes to the next new tab. Stored in data/numbers.json as
// { "<pid>": n }; when the pid is unknown the session id is the key.
const fs = require('fs');
const os = require('os');
const path = require('path');

const CC_HOME = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

// Claude Code keeps <claude home>/sessions/<pid>.json for every running process with its current session.
function liveProcesses() {
  const bySession = new Map();
  let files;
  try { files = fs.readdirSync(path.join(CC_HOME, 'sessions')); } catch { return null; }
  for (const f of files) {
    if (!/^\d+\.json$/.test(f)) continue;
    try {
      const j = JSON.parse(fs.readFileSync(path.join(CC_HOME, 'sessions', f), 'utf8'));
      if (j.pid && j.sessionId && alive(j.pid)) bySession.set(String(j.sessionId), String(j.pid));
    } catch {}
  }
  return bySession;
}

function sleepSync(ms) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); }

function withLock(file, fn) {
  const lock = file + '.lock';
  let fd = null;
  for (let i = 0; i < 100 && fd === null; i++) {
    try { fd = fs.openSync(lock, 'wx'); } catch {
      try { if (Date.now() - fs.statSync(lock).mtimeMs > 3000) fs.unlinkSync(lock); } catch {}
      sleepSync(20);
    }
  }
  try { return fn(); } finally {
    if (fd !== null) { fs.closeSync(fd); try { fs.unlinkSync(lock); } catch {} }
  }
}

function numberFor(dataDir, sessionId) {
  fs.mkdirSync(dataDir, { recursive: true });
  const file = path.join(dataDir, 'numbers.json');
  return withLock(file, () => {
    let map = {};
    try { map = JSON.parse(fs.readFileSync(file, 'utf8')); } catch {}
    const live = liveProcesses();
    const key = (live && live.get(String(sessionId))) || String(sessionId);
    if (map[key]) return map[key];
    if (live) {
      const liveKeys = new Set([...live.values(), ...live.keys()]);
      for (const k of Object.keys(map)) if (!liveKeys.has(k)) delete map[k];
    }
    const used = new Set(Object.values(map));
    let n = 1;
    while (used.has(n)) n++;
    map[key] = n;
    fs.writeFileSync(file + '.tmp', JSON.stringify(map));
    fs.renameSync(file + '.tmp', file);
    return n;
  });
}

// "4 · Picsart earn campaign" -> "Picsart earn campaign"
function stripNumber(title) { return String(title || '').replace(/^\d+\s*·\s*/, ''); }

// Give every open VS Code tab a number (the panel runs this when it sees a tab without one).
function syncAll(dataDir) {
  let files = [];
  try { files = fs.readdirSync(path.join(CC_HOME, 'sessions')); } catch { return; }
  const sids = [];
  for (const f of files) {
    if (!/^\d+\.json$/.test(f)) continue;
    try {
      const j = JSON.parse(fs.readFileSync(path.join(CC_HOME, 'sessions', f), 'utf8'));
      if (j.entrypoint === 'claude-vscode' && j.pid && j.sessionId && alive(j.pid)) sids.push({ sid: String(j.sessionId), started: j.startedAt || 0 });
    } catch {}
  }
  // Older tabs get the smaller numbers.
  for (const s of sids.sort((a, b) => a.started - b.started)) numberFor(dataDir, s.sid);
}

module.exports = { numberFor, stripNumber };

if (require.main === module && process.argv.includes('--sync')) {
  syncAll(path.join(process.env.CLUMSY_SLOTH_DIR || path.join(__dirname, '..'), 'data'));
}
