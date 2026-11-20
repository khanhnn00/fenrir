use crate::events::{AgentInfo, EventKind, HookEvent};
use std::collections::HashSet;
use std::sync::Mutex;

/// A subagent whose transcript has been silent this long is no longer counted as running.
const RUNNING_WINDOW_MS: i64 = 10 * 60 * 1000;
/// A subagent seen by SubagentStart is kept this long while the hook's directory scan does not list it yet.
const START_GRACE_MS: i64 = 15_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TrackedState {
    Working,
    Idle,
    NeedsInput,
    /// The main turn stopped but subagents are still running.
    AgentsRunning,
}

/// What the app should tell the user about a transition.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Notice {
    /// The main turn stopped and no subagent is running.
    Done,
    NeedsInput,
    /// The last running subagent finished after the main turn had stopped.
    AgentsDone,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Update {
    pub state: TrackedState,
    pub agents: u32,
    /// Description of the longest-running subagent.
    pub first_agent: Option<String>,
    pub notice: Option<Notice>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Main {
    Working,
    Idle,
    NeedsInput,
}

struct Agent {
    id: String,
    desc: String,
    last_ms: i64,
}

struct Inner {
    main: Main,
    claude_session: String,
    agents: Vec<Agent>,
    /// Subagents whose SubagentStop was seen; a directory scan that still lists them does not revive them.
    stopped: HashSet<String>,
    shown: (TrackedState, u32),
}

impl Inner {
    fn running(&self, now: i64) -> impl Iterator<Item = &Agent> {
        self.agents.iter().filter(move |a| now - a.last_ms <= RUNNING_WINDOW_MS)
    }

    fn state(&self, now: i64) -> TrackedState {
        match self.main {
            Main::Working => TrackedState::Working,
            Main::NeedsInput => TrackedState::NeedsInput,
            Main::Idle if self.running(now).next().is_some() => TrackedState::AgentsRunning,
            Main::Idle => TrackedState::Idle,
        }
    }

    fn upsert(&mut self, id: &str, desc: &str, last_ms: i64) {
        match self.agents.iter_mut().find(|a| a.id == id) {
            Some(a) => {
                a.last_ms = a.last_ms.max(last_ms);
                if !desc.is_empty() {
                    a.desc = desc.into();
                }
            }
            None => self.agents.push(Agent { id: id.into(), desc: desc.into(), last_ms }),
        }
    }

    /// Takes the hook's directory scan as the truth about which subagents run.
    fn reconcile(&mut self, scan: &[crate::events::AgentInfo], ts: i64) {
        for a in scan {
            if self.stopped.contains(&a.id) {
                continue;
            }
            self.upsert(&a.id, &a.desc, a.mtime);
        }
        self.agents.retain(|a| scan.iter().any(|s| s.id == a.id) || ts - a.last_ms <= START_GRACE_MS);
    }

    fn update(&mut self, now: i64, notice: Option<Notice>) -> Update {
        self.agents.retain(|a| now - a.last_ms <= RUNNING_WINDOW_MS);
        let state = self.state(now);
        let agents = self.agents.len() as u32;
        let notice = notice.or((self.shown.0 == TrackedState::AgentsRunning && state == TrackedState::Idle).then_some(Notice::AgentsDone));
        self.shown = (state, agents);
        Update { state, agents, first_agent: self.agents.first().map(|a| a.desc.clone()), notice }
    }
}

/// Agent state of one session: the main turn plus its running subagents.
#[derive(uniffi::Object)]
pub struct AgentTracker {
    inner: Mutex<Inner>,
}

#[uniffi::export]
impl AgentTracker {
    #[uniffi::constructor]
    pub fn new() -> Self {
        let inner = Inner { main: Main::Idle, claude_session: String::new(), agents: vec![], stopped: HashSet::new(), shown: (TrackedState::Idle, 0) };
        AgentTracker { inner: Mutex::new(inner) }
    }

    /// Feeds one hook event; `now_ms` is the app's clock.
    pub fn apply(&self, e: HookEvent, now_ms: i64) -> Update {
        let mut t = self.inner.lock().unwrap();
        if !e.claude_session.is_empty() && e.claude_session != t.claude_session {
            if !t.claude_session.is_empty() {
                t.agents.clear();
                t.stopped.clear();
            }
            t.claude_session = e.claude_session.clone();
        }
        if let Some(scan) = &e.agents {
            t.reconcile(scan, e.ts_ms);
        }
        let mut notice = None;
        match e.kind {
            EventKind::Working => t.main = Main::Working,
            EventKind::Idle => {
                t.main = Main::Idle;
                notice = Some(Notice::Done);
            }
            EventKind::NeedsInput => {
                t.main = Main::NeedsInput;
                notice = Some(Notice::NeedsInput);
            }
            EventKind::SubagentStart => {
                if let Some(id) = &e.agent_id {
                    t.stopped.remove(id);
                    let desc = e.agents.iter().flatten().find(|a| &a.id == id).map(|a| a.desc.clone()).or(e.agent_type.clone()).unwrap_or_default();
                    t.upsert(id, &desc, e.ts_ms);
                }
            }
            EventKind::SubagentStop => {
                if let Some(id) = &e.agent_id {
                    t.agents.retain(|a| &a.id != id);
                    t.stopped.insert(id.clone());
                }
            }
        }
        let mut u = t.update(now_ms, notice);
        // "Done" is only for a turn that stops with nothing left running.
        if u.state == TrackedState::AgentsRunning && u.notice == Some(Notice::Done) {
            u.notice = None;
        }
        u
    }

    /// Subagents counted as running now, longest-running first.
    pub fn agents(&self, now_ms: i64) -> Vec<AgentInfo> {
        let t = self.inner.lock().unwrap();
        t.running(now_ms).map(|a| AgentInfo { id: a.id.clone(), desc: a.desc.clone(), mtime: a.last_ms }).collect()
    }

    /// Call periodically: returns an update when subagents aged out and the state or count changed.
    /// Ids of subagents counted as running now (to poll their transcripts between hook events).
    pub fn running_ids(&self, now_ms: i64) -> Vec<String> {
        let t = self.inner.lock().unwrap();
        t.running(now_ms).map(|a| a.id.clone()).collect()
    }

    /// Fresh transcript mtimes from a poll; only extends agents already tracked and not stopped.
    pub fn refresh(&self, scan: Vec<AgentInfo>) {
        let mut t = self.inner.lock().unwrap();
        for a in scan {
            if !t.stopped.contains(&a.id) && t.agents.iter().any(|x| x.id == a.id) {
                t.upsert(&a.id, "", a.mtime);
            }
        }
    }

    pub fn tick(&self, now_ms: i64) -> Option<Update> {
        let mut t = self.inner.lock().unwrap();
        let before = t.shown;
        let u = t.update(now_ms, None);
        ((u.state, u.agents) != before).then_some(u)
    }
}

impl Default for AgentTracker {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::AgentInfo;

    fn ev(kind: EventKind, ts: i64) -> HookEvent {
        HookEvent { kind, cwd: "/w".into(), claude_session: "s".into(), fenrir_session: Some(1), project_id: Some(1), message: None, ts_ms: ts, agent_id: None, agent_type: None, agents: None, title: None, prompt: None, ordinal: None, tmux_session: None }
    }
    fn start(id: &str, ts: i64) -> HookEvent {
        HookEvent { agent_id: Some(id.into()), agent_type: Some("worker".into()), ..ev(EventKind::SubagentStart, ts) }
    }
    fn stop(id: &str, ts: i64) -> HookEvent {
        HookEvent { agent_id: Some(id.into()), ..ev(EventKind::SubagentStop, ts) }
    }
    fn scan(id: &str, desc: &str, mtime: i64) -> AgentInfo {
        AgentInfo { id: id.into(), desc: desc.into(), mtime }
    }

    #[test]
    fn main_stop_with_agents_waits_for_the_last_one() {
        let t = AgentTracker::new();
        assert_eq!(t.apply(ev(EventKind::Working, 1000), 1000).state, TrackedState::Working);
        let mut a = start("a1", 2000);
        a.agents = Some(vec![]);
        assert_eq!(t.apply(a, 2000).state, TrackedState::Working);
        t.apply(start("a2", 2100), 2100);
        let u = t.apply(ev(EventKind::Idle, 3000), 3000);
        assert_eq!((u.state, u.agents, u.notice), (TrackedState::AgentsRunning, 2, None));
        let u = t.apply(stop("a1", 4000), 4000);
        assert_eq!((u.state, u.agents, u.notice), (TrackedState::AgentsRunning, 1, None));
        let u = t.apply(stop("a2", 5000), 5000);
        assert_eq!((u.state, u.agents, u.notice), (TrackedState::Idle, 0, Some(Notice::AgentsDone)));
    }

    #[test]
    fn lists_running_agents_and_drops_stopped_ones() {
        let t = AgentTracker::new();
        let mut s = start("a1", 1100);
        s.agents = Some(vec![scan("a1", "Fix the PDF bug", 1100)]);
        t.apply(s, 1100);
        t.apply(start("a2", 1200), 1200);
        let l = t.agents(1300);
        assert_eq!(l.iter().map(|a| (a.id.as_str(), a.desc.as_str())).collect::<Vec<_>>(), vec![("a1", "Fix the PDF bug"), ("a2", "worker")]);
        t.apply(stop("a1", 1400), 1400);
        assert_eq!(t.agents(1500).len(), 1);
    }

    #[test]
    fn main_stop_with_no_agents_is_done() {
        let t = AgentTracker::new();
        t.apply(ev(EventKind::Working, 1000), 1000);
        let u = t.apply(ev(EventKind::Idle, 2000), 2000);
        assert_eq!((u.state, u.notice), (TrackedState::Idle, Some(Notice::Done)));
    }

    #[test]
    fn agents_finishing_while_main_works_do_not_notify() {
        let t = AgentTracker::new();
        t.apply(ev(EventKind::Working, 1000), 1000);
        t.apply(start("a1", 1100), 1100);
        let u = t.apply(stop("a1", 1200), 1200);
        assert_eq!((u.state, u.notice), (TrackedState::Working, None));
    }

    #[test]
    fn card_shows_the_first_agent_description_from_the_scan() {
        let t = AgentTracker::new();
        t.apply(ev(EventKind::Working, 1000), 1000);
        let mut s = start("a1", 1100);
        s.agents = Some(vec![scan("a1", "Fix the PDF bug", 1100)]);
        t.apply(s, 1100);
        let mut s = start("a2", 1200);
        s.agents = Some(vec![scan("a1", "Fix the PDF bug", 1150), scan("a2", "Rebase", 1200)]);
        t.apply(s, 1200);
        let u = t.apply(ev(EventKind::Idle, 2000), 2000);
        assert_eq!((u.state, u.agents, u.first_agent.as_deref()), (TrackedState::AgentsRunning, 2, Some("Fix the PDF bug")));
    }

    #[test]
    fn start_without_scan_falls_back_to_agent_type() {
        let t = AgentTracker::new();
        t.apply(start("a1", 1000), 1000);
        let u = t.apply(ev(EventKind::Idle, 1500), 1500);
        assert_eq!((u.state, u.first_agent.as_deref()), (TrackedState::AgentsRunning, Some("worker")));
    }

    #[test]
    fn stale_agent_is_ignored_and_ages_out() {
        let t = AgentTracker::new();
        t.apply(ev(EventKind::Working, 0), 0);
        let mut i = ev(EventKind::Idle, 1_000_000);
        i.agents = Some(vec![scan("old", "forgotten", 1_000_000 - RUNNING_WINDOW_MS - 1)]);
        let u = t.apply(i, 1_000_000);
        assert_eq!((u.state, u.agents, u.notice), (TrackedState::Idle, 0, Some(Notice::Done)));

        // A running agent that goes silent ages out through tick and ends the "agents running" state.
        let t = AgentTracker::new();
        t.apply(start("a1", 0), 0);
        assert_eq!(t.apply(ev(EventKind::Idle, 100), 100).state, TrackedState::AgentsRunning);
        assert_eq!(t.tick(RUNNING_WINDOW_MS), None);
        let u = t.tick(RUNNING_WINDOW_MS + 1).unwrap();
        assert_eq!((u.state, u.agents, u.notice), (TrackedState::Idle, 0, Some(Notice::AgentsDone)));
        assert_eq!(t.tick(RUNNING_WINDOW_MS + 2), None);
    }

    #[test]
    fn missed_stop_heals_from_the_scan() {
        let t = AgentTracker::new();
        t.apply(start("a1", 1000), 1000);
        t.apply(ev(EventKind::Idle, 2000), 2000);
        // SubagentStop never arrived; a later event's scan no longer lists a1.
        let mut n = stop("unrelated", 60_000);
        n.agents = Some(vec![]);
        let u = t.apply(n, 60_000);
        assert_eq!((u.state, u.agents, u.notice), (TrackedState::Idle, 0, Some(Notice::AgentsDone)));
    }

    #[test]
    fn fresh_start_survives_a_scan_that_is_not_there_yet_but_stopped_agents_stay_gone() {
        let t = AgentTracker::new();
        let mut s = start("a1", 1000);
        s.agents = Some(vec![]);
        assert_eq!(t.apply(s, 1000).agents, 1);
        t.apply(stop("a1", 2000), 2000);
        let mut i = ev(EventKind::Idle, 3000);
        i.agents = Some(vec![scan("a1", "late finished flag", 2900)]);
        assert_eq!(t.apply(i, 3000).agents, 0);
    }

    #[test]
    fn new_claude_session_drops_the_old_agents() {
        let t = AgentTracker::new();
        t.apply(start("a1", 1000), 1000);
        let mut w = ev(EventKind::Working, 2000);
        w.claude_session = "other".into();
        assert_eq!(t.apply(w, 2000).agents, 0);
    }

    #[test]
    fn polled_mtime_keeps_a_long_subagent_running() {
        let t = AgentTracker::new();
        t.apply(start("w", 1_000), 1_000);
        t.apply(HookEvent { agents: Some(vec![AgentInfo { id: "w".into(), desc: "job".into(), mtime: 1_000 }]), ..ev(EventKind::Idle, 2_000) }, 2_000);
        let late = 1_000 + RUNNING_WINDOW_MS + 60_000;
        t.refresh(vec![AgentInfo { id: "w".into(), desc: String::new(), mtime: late - 5_000 }]);
        assert_eq!(t.running_ids(late), vec!["w".to_string()]);
        t.refresh(vec![AgentInfo { id: "ghost".into(), desc: String::new(), mtime: late }]);
        assert_eq!(t.running_ids(late).len(), 1);
    }
}
