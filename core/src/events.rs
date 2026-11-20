use crate::registry::Project;
use serde::Deserialize;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum EventKind {
    /// UserPromptSubmit: the agent started working.
    Working,
    /// Stop: the agent finished and is idle.
    Idle,
    /// Notification: the agent needs input.
    NeedsInput,
    /// SubagentStart: a subagent began.
    SubagentStart,
    /// SubagentStop: a subagent finished.
    SubagentStop,
}

/// A subagent running right now, as read by the hook from the session's subagents directory.
/// A tmux client on a host and the Fenrir terminal it runs in (its FENRIR_SESSION).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TmuxAttach {
    pub fenrir_session: i64,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, uniffi::Record)]
pub struct AgentInfo {
    pub id: String,
    #[serde(default)]
    pub desc: String,
    /// Last write to the subagent transcript, epoch ms.
    #[serde(default)]
    pub mtime: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HookEvent {
    pub kind: EventKind,
    pub cwd: String,
    pub claude_session: String,
    /// Fenrir session id from the `FENRIR_SESSION` env var, when the agent ran inside Fenrir.
    pub fenrir_session: Option<i64>,
    /// Project whose directory contains `cwd`.
    pub project_id: Option<i64>,
    pub message: Option<String>,
    pub ts_ms: i64,
    /// SubagentStart/SubagentStop: the subagent concerned.
    pub agent_id: Option<String>,
    pub agent_type: Option<String>,
    /// Subagents the hook found running when it fired; `None` from hooks that predate the field.
    pub agents: Option<Vec<AgentInfo>>,
    /// Conversation name (user-set or generated) read from the transcript by the hook.
    pub title: Option<String>,
    /// UserPromptSubmit: the prompt that was submitted, shortened by the hook.
    pub prompt: Option<String>,
    /// Session number inside the project, from the Fenrir tmux session name the hook ran in (remote sessions).
    pub ordinal: Option<u32>,
    /// tmux session the hook ran in (TMUX set), whatever its name.
    pub tmux_session: Option<String>,
}

#[derive(Deserialize)]
struct Raw {
    cwd: String,
    #[serde(default)]
    session_id: String,
    event: String,
    #[serde(default)]
    ts: i64,
    #[serde(default)]
    fenrir_session: Option<serde_json::Value>,
    #[serde(default)]
    message: Option<String>,
    #[serde(default)]
    agent_id: Option<String>,
    #[serde(default)]
    agent_type: Option<String>,
    #[serde(default)]
    agents: Option<Vec<AgentInfo>>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    prompt: Option<String>,
    #[serde(default)]
    tmux_session: Option<String>,
}

fn canon(p: &str) -> PathBuf {
    std::fs::canonicalize(p).unwrap_or_else(|_| PathBuf::from(p))
}

/// Deepest local project whose directory contains `cwd`.
pub fn project_for_cwd(projects: &[Project], cwd: &str) -> Option<i64> {
    let cwd = canon(cwd);
    projects
        .iter()
        .filter(|p| p.host.is_none())
        .filter(|p| cwd.starts_with(canon(&p.path)))
        .max_by_key(|p| canon(&p.path).components().count())
        .map(|p| p.id)
}

/// Deepest project on `host` whose path contains `cwd` (remote paths are compared as written).
pub fn project_for_remote_cwd(projects: &[Project], host: &str, cwd: &str) -> Option<i64> {
    let cwd = Path::new(cwd);
    projects
        .iter()
        .filter(|p| p.host.as_deref() == Some(host))
        .filter(|p| cwd.starts_with(&p.path))
        .max_by_key(|p| Path::new(&p.path).components().count())
        .map(|p| p.id)
}

/// `(project id, ordinal)` from a Fenrir tmux session name.
pub fn fenrir_tmux_ids(name: &str) -> Option<(i64, u32)> {
    let rest = name.strip_prefix("fenrir-")?;
    let mut parts = rest.rsplitn(3, '-');
    let ordinal = parts.next()?.parse().ok()?;
    let pid = parts.next()?.parse().ok()?;
    parts.next()?;
    Some((pid, ordinal))
}

/// Parses one ndjson line from the local events file; `None` for malformed lines and events Fenrir does not track.
pub fn parse_line(line: &str, projects: &[Project]) -> Option<HookEvent> {
    parse_line_on(line, projects, None)
}

/// Same, for a line tailed from `host`: the cwd is matched against that host's projects.
pub fn parse_line_on(line: &str, projects: &[Project], host: Option<&str>) -> Option<HookEvent> {
    let raw: Raw = serde_json::from_str(line.trim()).ok()?;
    let kind = match raw.event.as_str() {
        "UserPromptSubmit" => EventKind::Working,
        "Stop" => EventKind::Idle,
        // The idle reminder ("Claude is waiting for your input") only means the turn is over; real prompts ask for permission.
        "Notification" if raw.message.as_deref().is_some_and(|m| m.contains("waiting for your input")) => EventKind::Idle,
        "Notification" => EventKind::NeedsInput,
        "SubagentStart" => EventKind::SubagentStart,
        "SubagentStop" => EventKind::SubagentStop,
        _ => return None,
    };
    let fenrir_session = raw.fenrir_session.and_then(|v| match v {
        serde_json::Value::Number(n) => n.as_i64(),
        serde_json::Value::String(s) => s.parse().ok(),
        _ => None,
    });
    // Fenrir names its tmux sessions `fenrir-<name>-<project id>-<ordinal>`: an exact project and session.
    let from_tmux = raw.tmux_session.as_deref().and_then(fenrir_tmux_ids);
    Some(HookEvent {
        kind,
        project_id: match (from_tmux, host) {
            (Some((pid, _)), _) if projects.iter().any(|p| p.id == pid) => Some(pid),
            (_, Some(h)) => project_for_remote_cwd(projects, h, &raw.cwd),
            (_, None) => project_for_cwd(projects, &raw.cwd),
        },
        ordinal: from_tmux.map(|(_, o)| o),
        tmux_session: raw.tmux_session.clone().filter(|t| !t.is_empty()),
        cwd: raw.cwd,
        claude_session: raw.session_id,
        fenrir_session,
        message: raw.message.filter(|m| !m.is_empty()),
        ts_ms: raw.ts,
        agent_id: raw.agent_id.filter(|a| !a.is_empty()),
        agent_type: raw.agent_type.filter(|a| !a.is_empty()),
        agents: raw.agents,
        title: raw.title.filter(|t| !t.is_empty()),
        prompt: raw.prompt.filter(|t| !t.is_empty()),
    })
}

/// Reads lines appended to the events file since the last call. Starts at the current end.
pub struct EventTail {
    path: PathBuf,
    offset: u64,
}

impl EventTail {
    pub fn new(path: &Path) -> Self {
        let offset = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
        EventTail { path: path.into(), offset }
    }

    pub fn read_new(&mut self, projects: &[Project]) -> Vec<HookEvent> {
        let Ok(mut f) = File::open(&self.path) else { return vec![] };
        let len = f.metadata().map(|m| m.len()).unwrap_or(0);
        if len < self.offset {
            self.offset = 0; // truncated or rotated
        }
        if len == self.offset || f.seek(SeekFrom::Start(self.offset)).is_err() {
            return vec![];
        }
        let mut buf = Vec::new();
        if f.take(len - self.offset).read_to_end(&mut buf).is_err() {
            return vec![];
        }
        // Only consume complete lines; a partial tail waits for the next poll.
        let Some(end) = buf.iter().rposition(|&b| b == b'\n') else { return vec![] };
        self.offset += end as u64 + 1;
        String::from_utf8_lossy(&buf[..end])
            .lines()
            .filter_map(|l| parse_line(l, projects))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn proj(id: i64, path: &str) -> Project {
        Project { id, name: format!("p{id}"), path: path.into(), host: None }
    }

    #[test]
    fn maps_cwd_to_deepest_project() {
        let ps = [proj(1, "/work/a"), proj(2, "/work/a/sub"), proj(3, "/work/ab")];
        assert_eq!(project_for_cwd(&ps, "/work/a/x/y"), Some(1));
        assert_eq!(project_for_cwd(&ps, "/work/a/sub/z"), Some(2));
        assert_eq!(project_for_cwd(&ps, "/work/ab"), Some(3));
        assert_eq!(project_for_cwd(&ps, "/elsewhere"), None);
    }

    fn remote(id: i64, host: &str, path: &str) -> Project {
        Project { id, name: format!("r{id}"), path: path.into(), host: Some(host.into()) }
    }

    #[test]
    fn maps_remote_cwd_by_host_and_path() {
        let ps = [remote(1, "dev1", "/srv/a"), remote(2, "dev1", "/srv/a/sub"), remote(3, "dev2", "/srv/a"), proj(4, "/srv/a")];
        assert_eq!(project_for_remote_cwd(&ps, "dev1", "/srv/a/x"), Some(1));
        assert_eq!(project_for_remote_cwd(&ps, "dev1", "/srv/a/sub/y"), Some(2));
        assert_eq!(project_for_remote_cwd(&ps, "dev2", "/srv/a"), Some(3));
        assert_eq!(project_for_remote_cwd(&ps, "dev1", "/srv/ab"), None);
        assert_eq!(project_for_remote_cwd(&ps, "dev9", "/srv/a"), None);
    }

    #[test]
    fn remote_lines_only_map_to_their_host() {
        let ps = [remote(1, "dev1", "/srv/a"), proj(2, "/srv/a")];
        let line = r#"{"cwd":"/srv/a/x","session_id":"s","event":"Notification","message":"Needs permission","ts":9}"#;
        let r = parse_line_on(line, &ps, Some("dev1")).unwrap();
        assert_eq!((r.kind, r.project_id, r.message.as_deref()), (EventKind::NeedsInput, Some(1), Some("Needs permission")));
        assert_eq!(parse_line_on(line, &ps, Some("dev2")).unwrap().project_id, None);
        assert_eq!(parse_line(line, &ps).unwrap().project_id, Some(2));
    }

    #[test]
    fn parses_hook_lines() {
        let ps = [proj(7, "/work/a")];
        let e = parse_line(
            r#"{"cwd":"/work/a","session_id":"s1","event":"Stop","ts":5,"fenrir_session":"3"}"#,
            &ps,
        )
        .unwrap();
        assert_eq!((e.kind, e.project_id, e.fenrir_session, e.ts_ms), (EventKind::Idle, Some(7), Some(3), 5));
        let n = parse_line(r#"{"cwd":"/x","event":"Notification","message":"Needs permission"}"#, &ps).unwrap();
        assert_eq!((n.kind, n.project_id, n.message.as_deref()), (EventKind::NeedsInput, None, Some("Needs permission")));
        assert!(parse_line(r#"{"cwd":"/x","event":"SessionStart"}"#, &ps).is_none());
        assert!(parse_line("not json", &ps).is_none());
    }

    #[test]
    fn parses_subagent_lines_and_the_running_scan() {
        let line = r#"{"cwd":"/w","session_id":"s","event":"SubagentStart","agent_id":"a1","agent_type":"worker","ts":7,"agents":[{"id":"a1","desc":"Fix it","mtime":6}]}"#;
        let e = parse_line(line, &[]).unwrap();
        assert_eq!((e.kind, e.agent_id.as_deref(), e.agent_type.as_deref()), (EventKind::SubagentStart, Some("a1"), Some("worker")));
        assert_eq!(e.agents, Some(vec![AgentInfo { id: "a1".into(), desc: "Fix it".into(), mtime: 6 }]));
        assert_eq!(parse_line(r#"{"cwd":"/w","event":"SubagentStop","agent_id":"a1"}"#, &[]).unwrap().agents, None);
    }

    #[test]
    fn parses_title_and_prompt() {
        let e = parse_line(r#"{"cwd":"/w","event":"UserPromptSubmit","title":"Fix login","prompt":"please fix"}"#, &[]).unwrap();
        assert_eq!((e.title.as_deref(), e.prompt.as_deref()), (Some("Fix login"), Some("please fix")));
        let e = parse_line(r#"{"cwd":"/w","event":"Stop","title":""}"#, &[]).unwrap();
        assert_eq!((e.title, e.prompt), (None, None));
    }

    #[test]
    fn tail_returns_only_new_complete_lines() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("events.ndjson");
        std::fs::write(&path, "{\"cwd\":\"/a\",\"event\":\"Stop\"}\n").unwrap();
        let mut tail = EventTail::new(&path);
        assert!(tail.read_new(&[]).is_empty());
        let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        f.write_all(b"{\"cwd\":\"/a\",\"event\":\"UserPromptSubmit\"}\n{\"cwd\":\"/a\",\"ev").unwrap();
        let got = tail.read_new(&[]);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].kind, EventKind::Working);
        f.write_all(b"ent\":\"Stop\"}\n").unwrap();
        assert_eq!(tail.read_new(&[]).len(), 1);
        assert!(tail.read_new(&[]).is_empty());
    }

    #[test]
    fn tmux_session_name_pins_project_and_ordinal() {
        assert_eq!(fenrir_tmux_ids("fenrir-Acme_Eval-5-2"), Some((5, 2)));
        assert_eq!(fenrir_tmux_ids("fenrir-my-app-12-3"), Some((12, 3)));
        assert_eq!(fenrir_tmux_ids("work"), None);
        assert_eq!(fenrir_tmux_ids("fenrir-x-a-1"), None);
    }

    #[test]
    fn idle_reminder_is_not_needs_input() {
        let idle = parse_line(r#"{"cwd":"/x","event":"Notification","message":"Claude is waiting for your input"}"#, &[]).unwrap();
        assert_eq!(idle.kind, EventKind::Idle);
        let ask = parse_line(r#"{"cwd":"/x","event":"Notification","message":"Claude needs your permission to use Bash"}"#, &[]).unwrap();
        assert_eq!(ask.kind, EventKind::NeedsInput);
    }
}
