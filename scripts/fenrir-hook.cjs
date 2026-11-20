#!/usr/bin/env node
// Claude Code hook: appends {cwd, session_id, event, ts, fenrir_session, message, agents} to
// $FENRIR_HOME/events.ndjson (default ~/.fenrir) so Fenrir can show agent state.
// `agents` lists the session's running subagents, read from
// <transcript dir>/<session id>/subagents (meta not finished, transcript written within 10 minutes).
// `title` is the conversation name from the transcript (user-set name, else the generated title);
// `prompt` is the submitted prompt of a UserPromptSubmit.
// Never blocks or fails the agent: every error is swallowed.
const fs = require('fs');
const os = require('os');
const path = require('path');

const RUNNING_WINDOW_MS = 10 * 60 * 1000;

function runningAgents(transcript) {
  const out = [];
  if (!transcript) return out;
  const dir = path.join(path.dirname(transcript), path.basename(transcript, '.jsonl'), 'subagents');
  let names = [];
  try {
    names = fs.readdirSync(dir);
  } catch (_) {
    return out;
  }
  for (const n of names) {
    const m = /^agent-(.+)\.meta\.json$/.exec(n);
    if (!m) continue;
    try {
      const mtime = fs.statSync(path.join(dir, `agent-${m[1]}.jsonl`)).mtimeMs;
      if (Date.now() - mtime > RUNNING_WINDOW_MS) continue;
      const meta = JSON.parse(fs.readFileSync(path.join(dir, n), 'utf8'));
      if (meta.finished === true) continue;
      out.push({ id: m[1], desc: String(meta.description || meta.agentType || 'agent').slice(0, 120), mtime: Math.round(mtime) });
    } catch (_) {}
  }
  return out;
}

// Last agent-name (set by the user) or ai-title entry in the transcript's tail.
function conversationTitle(transcript) {
  if (!transcript) return '';
  let fd;
  try {
    fd = fs.openSync(transcript, 'r');
    const size = fs.fstatSync(fd).size;
    const len = Math.min(size, 4 * 1024 * 1024);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, size - len);
    let named = '';
    let generated = '';
    for (const l of buf.toString('utf8').split('\n')) {
      if (!l.includes('"agent-name"') && !l.includes('"ai-title"')) continue;
      try {
        const j = JSON.parse(l);
        if (j.type === 'agent-name' && j.agentName) named = String(j.agentName);
        if (j.type === 'ai-title' && j.aiTitle) generated = String(j.aiTitle);
      } catch (_) {}
    }
    return (named || generated).slice(0, 120);
  } catch (_) {
    return '';
  } finally {
    if (fd !== undefined) try { fs.closeSync(fd); } catch (_) {}
  }
}

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => (input += c));
process.stdin.on('end', () => {
  try {
    const p = JSON.parse(input);
    const dir = process.env.FENRIR_HOME || path.join(os.homedir(), '.fenrir');
    fs.mkdirSync(dir, { recursive: true });
    const line = {
      cwd: p.cwd || process.cwd(),
      session_id: p.session_id || '',
      event: p.hook_event_name || '',
      ts: Date.now(),
    };
    if (p.agent_id) line.agent_id = String(p.agent_id);
    if (p.agent_type) line.agent_type = String(p.agent_type);
    line.agents = runningAgents(p.transcript_path);
    const title = conversationTitle(p.transcript_path);
    if (title) line.title = title;
    if (p.prompt) line.prompt = String(p.prompt).replace(/\s+/g, ' ').trim().slice(0, 120);
    if (process.env.FENRIR_SESSION) line.fenrir_session = process.env.FENRIR_SESSION;
    // Remote sessions run in a Fenrir tmux session (env vars do not cross ssh): its name identifies the session.
    if (process.env.TMUX) {
      try {
        const name = require('child_process').execFileSync('tmux', ['display-message', '-p', '#S'], { encoding: 'utf8', timeout: 1000, stdio: ['ignore', 'pipe', 'ignore'] }).trim();
        if (name) line.tmux_session = name;
      } catch (_) {}
    }
    if (p.message) line.message = String(p.message).slice(0, 300);
    fs.appendFileSync(path.join(dir, 'events.ndjson'), JSON.stringify(line) + '\n');
  } catch (_) {}
  process.exit(0);
});
