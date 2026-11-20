#!/usr/bin/env node
// Wires scripts/fenrir-hook.cjs into ~/.claude/settings.json for UserPromptSubmit, Stop,
// Notification, SubagentStart and SubagentStop. Backs the file up first; running it again changes nothing.
const fs = require('fs');
const os = require('os');
const path = require('path');

const settingsPath = path.join(os.homedir(), '.claude', 'settings.json');
const command = `node ${path.join(__dirname, 'fenrir-hook.cjs')}`;
const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
settings.hooks = settings.hooks || {};

let changed = false;
for (const event of ['UserPromptSubmit', 'Stop', 'Notification', 'SubagentStart', 'SubagentStop']) {
  const groups = (settings.hooks[event] = settings.hooks[event] || []);
  const wired = groups.some((g) => (g.hooks || []).some((h) => (h.command || '').includes('fenrir-hook.cjs')));
  if (!wired) {
    groups.push({ hooks: [{ type: 'command', command, timeout: 5 }] });
    changed = true;
  }
}
if (!changed) {
  console.log('fenrir hooks already wired');
  process.exit(0);
}
const backup = `${settingsPath}.bak-fenrir-${Date.now()}`;
fs.copyFileSync(settingsPath, backup);
const tmp = `${settingsPath}.fenrir-tmp`;
fs.writeFileSync(tmp, JSON.stringify(settings, null, 2) + '\n');
fs.renameSync(tmp, settingsPath);
console.log(`wired fenrir hooks; backup at ${backup}`);
