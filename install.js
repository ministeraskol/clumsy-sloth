#!/usr/bin/env node
// Clumsy Sloth installer (Windows). Runs in place: the sloth lives in this folder.
//   node install.js              register the hooks, start at login, start the sloth now
//   node install.js --uninstall  remove the hooks and the login entry, stop the sloth
// Claude Code's settings.json is backed up to settings.json.clumsy-sloth.bak before it is changed.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, spawn } = require('child_process');

const HERE = __dirname;
const CLAUDE_HOME = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const SETTINGS = path.join(CLAUDE_HOME, 'settings.json');
const RUN_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run';
const RUN_NAME = 'ClumsySloth';
const uninstall = process.argv.includes('--uninstall');

const hookPath = (name) => path.join(HERE, 'hooks', name).split(path.sep).join('/');
const STATUS = `node "${hookPath('status.js')}"`;
const PERMISSION = `node "${hookPath('permission.js')}"`;
const ours = (cmd) => typeof cmd === 'string' && (cmd.includes(hookPath('status.js')) || cmd.includes(hookPath('permission.js')));

function readSettings() {
  if (!fs.existsSync(SETTINGS)) return {};
  return JSON.parse(fs.readFileSync(SETTINGS, 'utf8').replace(/^﻿/, ''));
}

// Drop every hook entry that runs one of our scripts, keep everything else untouched.
function removeOurHooks(settings) {
  const hooks = settings.hooks || {};
  for (const event of Object.keys(hooks)) {
    hooks[event] = hooks[event]
      .map((group) => Object.assign({}, group, { hooks: (group.hooks || []).filter((h) => !ours(h.command)) }))
      .filter((group) => group.hooks.length > 0);
    if (hooks[event].length === 0) delete hooks[event];
  }
  settings.hooks = hooks;
}

function addHook(settings, event, matcher, hook) {
  settings.hooks[event] = settings.hooks[event] || [];
  const group = { hooks: [hook] };
  if (matcher) group.matcher = matcher;
  settings.hooks[event].push(group);
}

function stopPanel() {
  try {
    execFileSync('powershell.exe', ['-NoProfile', '-Command',
      "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*clumsy-sloth*panel.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"],
    { stdio: 'ignore' });
  } catch {}
}

function main() {
  if (process.platform !== 'win32') { console.error('Clumsy Sloth runs on Windows only.'); process.exit(1); }
  const settings = readSettings();
  if (fs.existsSync(SETTINGS)) fs.copyFileSync(SETTINGS, SETTINGS + '.clumsy-sloth.bak');
  removeOurHooks(settings);

  if (uninstall) {
    fs.writeFileSync(SETTINGS, JSON.stringify(settings, null, 2) + '\n');
    try { execFileSync('reg', ['delete', RUN_KEY, '/v', RUN_NAME, '/f'], { stdio: 'ignore' }); } catch {}
    stopPanel();
    console.log('Clumsy Sloth removed. You can delete this folder now.');
    return;
  }

  const status = { type: 'command', command: STATUS, timeout: 15, async: true };
  for (const event of ['UserPromptSubmit', 'Stop', 'Notification', 'SessionEnd', 'PostToolUse']) addHook(settings, event, null, status);
  addHook(settings, 'PreToolUse', 'AskUserQuestion', status);
  // The tab shows its own prompt at the same time; the hook only waits for an answer from the sloth.
  addHook(settings, 'PermissionRequest', null, { type: 'command', command: PERMISSION, timeout: 600 });
  fs.mkdirSync(CLAUDE_HOME, { recursive: true });
  fs.writeFileSync(SETTINGS, JSON.stringify(settings, null, 2) + '\n');

  for (const d of ['sessions', 'requests', 'answers']) fs.mkdirSync(path.join(HERE, 'data', d), { recursive: true });
  const vbs = path.join(HERE, 'start.vbs');
  execFileSync('reg', ['add', RUN_KEY, '/v', RUN_NAME, '/t', 'REG_SZ', '/d', `wscript.exe "${vbs}"`, '/f'], { stdio: 'ignore' });

  stopPanel();
  spawn('wscript.exe', [vbs], { detached: true, stdio: 'ignore' }).unref();
  console.log('Clumsy Sloth installed. The sloth sits at the bottom-left of your screen.');
  console.log('Open VS Code Claude Code tabs pick up the hooks on their next message; new tabs right away.');
}

main();
