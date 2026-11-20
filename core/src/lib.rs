mod agent_tracker;
mod coder;
mod command;
mod error;
mod events;
mod files;
mod forward;
mod ports;
mod claude_title;
mod registry;
mod remote_events;
mod remote_hooks;
mod session;
mod sftp;
mod ssh;
mod transfer;
mod transfer_run;
#[cfg(test)]
mod transfer_tests;

pub use agent_tracker::{AgentTracker, Notice, TrackedState, Update};
pub use coder::CoderWorkspace;
pub use error::FenrirError;
pub use events::{AgentInfo, EventKind, HookEvent, TmuxAttach};
pub use files::FileEntry;
pub use forward::{ForwardStatus, PortForward};
pub use ports::ListeningPort;
pub use registry::{Machine, Project};
pub use session::OutputListener;
pub use sftp::SftpEntry;
pub use transfer::{ConflictPolicy, Direction, TransferItem, TransferState};

use events::EventTail;
use registry::Registry;
use remote_events::RemoteTails;
use session::Session;
use transfer::Transfers;
use ssh::Ssh;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

uniffi::setup_scaffolding!();

struct Entry {
    project_id: i64,
    ordinal: u32,
    session: Session,
    listener: Arc<dyn OutputListener>,
}

/// Entry point used by the Swift app.
#[derive(uniffi::Object)]
pub struct FenrirCore {
    data_dir: PathBuf,
    registry: Mutex<Registry>,
    sessions: Mutex<HashMap<i64, Entry>>,
    next_session: AtomicI64,
    tail: Mutex<EventTail>,
    ssh: Ssh,
    remote_tails: RemoteTails,
    transfers: Transfers,
    forwards: forward::Forwards,
}

#[uniffi::export]
impl FenrirCore {
    /// `data_dir` is created if missing (the app passes `~/.fenrir`).
    #[uniffi::constructor]
    pub fn new(data_dir: String) -> Result<Arc<Self>, FenrirError> {
        transfer_run::ignore_sigpipe();
        let dir = PathBuf::from(data_dir);
        std::fs::create_dir_all(&dir).map_err(|e| FenrirError::Db(e.to_string()))?;
        let db = dir.join("fenrir.db");
        let ssh = Ssh::new(&dir);
        Ok(Arc::new(FenrirCore {
            registry: Mutex::new(Registry::open(&db)?),
            sessions: Mutex::new(HashMap::new()),
            next_session: AtomicI64::new(1),
            tail: Mutex::new(EventTail::new(&dir.join("events.ndjson"))),
            remote_tails: RemoteTails::new(ssh.clone()),
            transfers: Transfers::new(ssh.clone()),
            forwards: forward::Forwards::new(ssh.clone(), &db)?,
            ssh,
            data_dir: dir,
        }))
    }

    pub fn list_projects(&self) -> Result<Vec<Project>, FenrirError> {
        self.registry.lock().unwrap().list()
    }

    /// `host` is the ssh alias of a remote machine, `None` for Local.
    pub fn add_project(&self, name: String, path: String, host: Option<String>) -> Result<Project, FenrirError> {
        self.registry.lock().unwrap().add(&name, &path, host.as_deref())
    }

    /// Local first, then the remote machines in the order they were added.
    pub fn list_machines(&self) -> Result<Vec<Machine>, FenrirError> {
        self.registry.lock().unwrap().list_machines()
    }

    pub fn add_machine(&self, name: String, host: String) -> Result<Machine, FenrirError> {
        self.registry.lock().unwrap().add_machine(&name, &host)
    }

    pub fn rename_machine(&self, id: i64, name: String) -> Result<(), FenrirError> {
        self.registry.lock().unwrap().rename_machine(id, &name)
    }

    /// Removes a remote machine with its projects and sessions (tmux sessions on the host keep running).
    pub fn remove_machine(&self, id: i64) -> Result<(), FenrirError> {
        let gone = self.registry.lock().unwrap().remove_machine(id)?;
        self.sessions.lock().unwrap().retain(|_, e| !gone.contains(&e.project_id));
        Ok(())
    }

    /// Checks that `ssh <host>` works without prompts; returns the remote home directory.
    pub fn test_machine(&self, host: String) -> Result<String, FenrirError> {
        self.ssh.home(&host)
    }

    pub fn rename_project(&self, id: i64, name: String) -> Result<(), FenrirError> {
        self.registry.lock().unwrap().rename_project(id, &name)
    }

    /// Orders the listed projects as given; the sidebar shows them in this order.
    pub fn reorder_projects(&self, ids: Vec<i64>) -> Result<(), FenrirError> {
        self.registry.lock().unwrap().reorder(&ids)
    }

    /// Names a Claude conversation the way `/rename` does, by appending to its transcript on this Mac
    /// (`host` None) or on the host. False when that transcript does not exist yet.
    pub fn rename_claude_session(&self, host: Option<String>, cwd: String, claude_session: String, name: String) -> Result<bool, FenrirError> {
        match host {
            None => claude_title::rename_local(std::path::Path::new(&std::env::var("HOME").unwrap_or_default()), &cwd, &claude_session, &name),
            Some(h) => {
                let cmd = claude_title::remote_cmd(&cwd, &claude_session)?;
                let out = self.ssh.run(&h, &cmd, Some(claude_title::entries(&claude_session, &name).as_bytes()), std::time::Duration::from_secs(15))?;
                Ok(out.trim() == "ok")
            }
        }
    }

    pub fn remove_project(&self, id: i64) -> Result<(), FenrirError> {
        self.sessions.lock().unwrap().retain(|_, e| e.project_id != id);
        self.registry.lock().unwrap().remove(id)
    }

    /// Starts a new PTY session for the project and returns its id. The child gets
    /// `FENRIR_SESSION` so agent hooks can say which session they ran in. `ordinal` is the
    /// project's session number; for remote projects it names the tmux session on the host.
    pub fn new_session(
        &self,
        project_id: i64,
        ordinal: u32,
        cols: u16,
        rows: u16,
        listener: Arc<dyn OutputListener>,
    ) -> Result<i64, FenrirError> {
        let project = self.project(project_id)?;
        let id = self.next_session.fetch_add(1, Ordering::SeqCst);
        let session = self.spawn(&project, id, cols, rows, listener.clone())?;
        self.sessions.lock().unwrap().insert(id, Entry { project_id, ordinal, session, listener });
        Ok(id)
    }

    /// Starts the session's command again under the same id (after an ssh drop); for remote
    /// projects this opens a fresh shell over ssh; a tmux the user started there is still running.
    pub fn reconnect_session(&self, id: i64, cols: u16, rows: u16) -> Result<(), FenrirError> {
        let (project_id, listener) = match self.sessions.lock().unwrap().get(&id) {
            Some(e) => (e.project_id, e.listener.clone()),
            None => return Err(FenrirError::Session(format!("no session {id}"))),
        };
        let project = self.project(project_id)?;
        let session = self.spawn(&project, id, cols, rows, listener)?;
        if let Some(e) = self.sessions.lock().unwrap().get_mut(&id) {
            e.session = session;
        }
        Ok(())
    }

    pub fn write_session(&self, id: i64, data: Vec<u8>) -> Result<(), FenrirError> {
        match self.sessions.lock().unwrap().get_mut(&id) {
            Some(e) => e.session.write(&data),
            None => Err(FenrirError::Session(format!("no session {id}"))),
        }
    }

    pub fn resize_session(&self, id: i64, cols: u16, rows: u16) -> Result<(), FenrirError> {
        match self.sessions.lock().unwrap().get(&id) {
            Some(e) => e.session.resize(cols, rows),
            None => Ok(()),
        }
    }

    pub fn session_alive(&self, id: i64) -> bool {
        self.sessions.lock().unwrap().get_mut(&id).is_some_and(|e| e.session.is_alive())
    }

    /// Kills and forgets the session; a tmux the user started on the host keeps running.
    pub fn close_session(&self, id: i64) {
        self.sessions.lock().unwrap().remove(&id);
    }

    /// Agent hook events appended to `events.ndjson` since the previous call.
    pub fn poll_events(&self) -> Vec<HookEvent> {
        let projects = self.registry.lock().unwrap().list().unwrap_or_default();
        let mut events = self.tail.lock().unwrap().read_new(&projects);
        for (host, line) in self.remote_tails.drain() {
            events.extend(events::parse_line_on(&line, &projects, Some(&host)));
        }
        events
    }

    /// Children of a directory: .gitignore respected, `.git` hidden, folders first.
    pub fn list_dir(&self, dir: String) -> Vec<FileEntry> {
        files::list_dir(&dir)
    }

    /// Files under `root` whose relative path fuzzy-matches `query`, best first, at most `cap`.
    pub fn find_files(&self, root: String, query: String, cap: u32) -> Vec<FileEntry> {
        files::find_files(&root, &query, cap as usize)
    }

    /// Host aliases from `~/.ssh/config` (and plain `Include`d files); wildcard patterns are left out.
    pub fn ssh_hosts(&self) -> Vec<String> {
        ssh::config_hosts(&std::env::var("HOME").unwrap_or_default())
    }

    /// Coder workspaces from `coder list -o json` (read-only), each with the ssh host name to save.
    pub fn coder_workspaces(&self) -> Result<Vec<CoderWorkspace>, FenrirError> {
        coder::list()
    }

    /// The remote user's home directory.
    pub fn remote_home(&self, host: String) -> Result<String, FenrirError> {
        self.ssh.home(&host)
    }

    /// Children of a remote directory, same rules as `list_dir`.
    /// Last-write times of subagent transcripts of a Claude session, so long subagents stay counted
    /// as running between hook events. `host` None reads this Mac; ids without a transcript are omitted.
    /// Last write to the main transcript of a Claude session, epoch ms (whole seconds for remote
    /// hosts); `None` when it cannot be read. A write after a Stop means a stop hook kept claude going.
    pub fn transcript_mtime(&self, host: Option<String>, cwd: String, claude_session: String) -> Option<i64> {
        if !claude_session.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') { return None; }
        let slug: String = cwd.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
        let rel = format!(".claude/projects/{slug}/{claude_session}.jsonl");
        match host {
            None => {
                let t = std::fs::metadata(std::path::Path::new(&std::env::var("HOME").ok()?).join(&rel)).ok()?.modified().ok()?;
                Some(t.duration_since(std::time::UNIX_EPOCH).ok()?.as_millis() as i64)
            }
            Some(h) => {
                let out = self.ssh.run(&h, &format!("stat -c %Y \"$HOME/{rel}\""), None, std::time::Duration::from_secs(10)).ok()?;
                out.trim().parse::<i64>().ok().map(|s| s * 1000)
            }
        }
    }

    pub fn agent_mtimes(&self, host: Option<String>, cwd: String, claude_session: String, ids: Vec<String>) -> Vec<AgentInfo> {
        let slug: String = cwd.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
        let ids: Vec<String> = ids.into_iter().filter(|i| i.chars().all(|c| c.is_ascii_alphanumeric())).collect();
        if ids.is_empty() || !claude_session.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') { return vec![]; }
        let rel = format!(".claude/projects/{slug}/{claude_session}/subagents");
        let mut out = vec![];
        match host {
            None => {
                let dir = std::path::Path::new(&std::env::var("HOME").unwrap_or_default()).join(&rel);
                for id in ids {
                    let m = std::fs::metadata(dir.join(format!("agent-{id}.jsonl"))).and_then(|m| m.modified());
                    if let Ok(t) = m { out.push(AgentInfo { id, desc: String::new(), mtime: t.duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0) }); }
                }
            }
            Some(h) => {
                let files: Vec<String> = ids.iter().map(|i| format!("agent-{i}.jsonl")).collect();
                let cmd = format!("cd \"$HOME/{rel}\" 2>/dev/null && stat -c '%n %Y' {} 2>/dev/null; true", files.join(" "));
                if let Ok(text) = self.ssh.run(&h, &cmd, None, std::time::Duration::from_secs(15)) {
                    for line in text.lines() {
                        let mut p = line.split_whitespace();
                        if let (Some(n), Some(t)) = (p.next(), p.next()) {
                            if let (Some(id), Ok(sec)) = (n.strip_prefix("agent-").and_then(|x| x.strip_suffix(".jsonl")), t.parse::<i64>()) {
                                out.push(AgentInfo { id: id.into(), desc: String::new(), mtime: sec * 1000 });
                            }
                        }
                    }
                }
            }
        }
        out
    }

    /// Which tmux session each Fenrir terminal on `host` is attached to, read from the
    /// FENRIR_SESSION of every tmux client process, so a relaunch can attach the same one again.
    pub fn remote_tmux_attachments(&self, host: String) -> Result<Vec<TmuxAttach>, FenrirError> {
        let cmd = r#"tmux list-clients -F '#{client_pid} #{session_name}' 2>/dev/null | while read -r p s; do f=$(tr '\0' '\n' < /proc/$p/environ 2>/dev/null | sed -n 's/^FENRIR_SESSION=//p'); [ -n "$f" ] && printf '%s %s\n' "$f" "$s"; done; true"#;
        let text = self.ssh.run(&host, cmd, None, std::time::Duration::from_secs(10))?;
        Ok(text
            .lines()
            .filter_map(|l| {
                let (id, name) = l.split_once(' ')?;
                Some(TmuxAttach { fenrir_session: id.trim().parse().ok()?, name: name.trim().to_string() })
            })
            .collect())
    }

    pub fn list_remote_dir(&self, host: String, dir: String) -> Result<Vec<FileEntry>, FenrirError> {
        self.ssh.list_dir(&host, &dir)
    }

    /// Remote counterpart of `find_files`.
    pub fn find_remote_files(&self, host: String, root: String, query: String, cap: u32) -> Result<Vec<FileEntry>, FenrirError> {
        self.ssh.find_files(&host, &root, &query, cap as usize)
    }

    /// Up to `max_bytes` of a remote file as text.
    pub fn read_remote_file(&self, host: String, path: String, max_bytes: u32) -> Result<String, FenrirError> {
        let bytes = self.ssh.read_file(&host, &path, max_bytes as usize)?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }

    /// Replaces a remote file with `data` (through a temp file, so readers never see half of it).
    pub fn write_remote_file(&self, host: String, path: String, data: Vec<u8>) -> Result<(), FenrirError> {
        self.ssh.write_file(&host, &path, &data)
    }

    /// Copies a remote file (up to `max_bytes`) to `local_path`.
    pub fn download_remote_file(&self, host: String, path: String, local_path: String, max_bytes: u32) -> Result<(), FenrirError> {
        let bytes = self.ssh.read_file(&host, &path, max_bytes as usize)?;
        std::fs::write(&local_path, bytes).map_err(|e| FenrirError::Invalid(e.to_string()))
    }

    /// Children of a folder on this Mac with size and date, folders first.
    pub fn sftp_list_local(&self, dir: String) -> Result<Vec<SftpEntry>, FenrirError> {
        sftp::list_local(&dir)
    }

    /// Children of a folder on `host` with size and date, folders first.
    pub fn sftp_list_remote(&self, host: String, dir: String) -> Result<Vec<SftpEntry>, FenrirError> {
        let out = self.ssh.run(&host, &sftp::remote_list_cmd(&dir), None, std::time::Duration::from_secs(30))?;
        Ok(sftp::parse_remote_list(&dir, &out))
    }

    /// Creates folder `name` in `dir` (on this Mac, or on `host`); returns its path.
    pub fn sftp_mkdir(&self, host: Option<String>, dir: String, name: String) -> Result<String, FenrirError> {
        sftp::validate_name(&name)?;
        match host {
            None => sftp::local_mkdir(&dir, &name),
            Some(h) => self.sftp_run(&h, &sftp::remote_mkdir_cmd(&dir, &name)).map(|_| sftp::join(&dir, &name)),
        }
    }

    /// Renames `path` within its folder; returns the new path.
    pub fn sftp_rename(&self, host: Option<String>, path: String, new_name: String) -> Result<String, FenrirError> {
        sftp::validate_name(&new_name)?;
        match host {
            None => sftp::local_rename(&path, &new_name),
            Some(h) => self.sftp_run(&h, &sftp::remote_rename_cmd(&path, &new_name)).map(|_| sftp::join(&sftp::parent(&path), &new_name)),
        }
    }

    /// Deletes a file or folder (recursively) on this Mac or on `host`. The caller confirms first.
    pub fn sftp_delete(&self, host: Option<String>, path: String) -> Result<(), FenrirError> {
        match host {
            None => sftp::local_delete(&path),
            Some(h) => self.sftp_run(&h, &sftp::remote_delete_cmd(&path)?).map(|_| ()),
        }
    }

    /// Queues one item: `src` is a path on the sending side, `dst_dir` the folder on the receiving side.
    pub fn start_transfer(
        &self,
        host: String,
        direction: Direction,
        src: String,
        dst_dir: String,
        policy: ConflictPolicy,
    ) -> Result<i64, FenrirError> {
        self.transfers.start(&host, direction, &src, &dst_dir, policy)
    }

    /// Every transfer in the queue, oldest first, with current progress.
    pub fn transfers(&self) -> Vec<TransferItem> {
        self.transfers.list()
    }

    /// Answers a transfer that is waiting on a name conflict (`Overwrite`, `Skip` or `Rename`).
    pub fn resolve_conflict(&self, id: i64, policy: ConflictPolicy) {
        self.transfers.resolve(id, policy)
    }

    pub fn cancel_transfer(&self, id: i64) {
        self.transfers.cancel(id)
    }

    pub fn retry_transfer(&self, id: i64) -> Result<(), FenrirError> {
        self.transfers.retry(id)
    }

    /// Drops finished transfers from the queue list.
    pub fn clear_finished_transfers(&self) {
        self.transfers.clear_finished()
    }

    /// Whether the Fenrir hook script is on the host and wired into its Claude settings. Read-only.
    pub fn remote_hooks_installed(&self, host: String) -> Result<bool, FenrirError> {
        remote_hooks::status(&self.ssh, &host)
    }

    /// Copies the hook script to the host and wires its `~/.claude/settings.json` (backup first,
    /// idempotent). Returns a short report. Only runs when the user asks.
    pub fn install_remote_hooks(&self, host: String) -> Result<String, FenrirError> {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as i64);
        remote_hooks::install(&self.ssh, &host, now)
    }

    /// Follows the host's `~/.fenrir/events.ndjson` so `poll_events` also reports its agents.
    pub fn watch_remote_events(&self, host: String) {
        self.remote_tails.ensure(&host);
    }

    /// Forwards `remote_port` of `host` to 127.0.0.1 here (`local_port` defaults to the same number).
    pub fn forward_add(&self, host: String, remote_port: u16, local_port: Option<u16>) -> Result<PortForward, FenrirError> {
        self.forwards.add(&host, remote_port, local_port)
    }

    /// Ends a forward and forgets it.
    pub fn forward_stop(&self, id: i64) -> Result<(), FenrirError> {
        self.forwards.stop(id)
    }

    /// Starts the saved forwards of `host` that are not running.
    pub fn forward_restore(&self, host: String) -> Result<(), FenrirError> {
        self.forwards.restore(&host)
    }

    pub fn forward_list(&self, host: String) -> Vec<PortForward> {
        self.forwards.list(&host)
    }

    /// Ends every forward process (app quit); saved forwards come back on the next launch.
    pub fn forward_stop_all(&self) {
        self.forwards.stop_all()
    }

    /// TCP ports listening on `host`.
    pub fn forward_detect(&self, host: String) -> Result<Vec<ListeningPort>, FenrirError> {
        let out = self.ssh.run(&host, ports::DETECT_CMD, None, std::time::Duration::from_secs(15))?;
        Ok(ports::parse_listening(&out))
    }
}

impl FenrirCore {
    fn sftp_run(&self, host: &str, cmd: &str) -> Result<String, FenrirError> {
        self.ssh.run(host, cmd, None, std::time::Duration::from_secs(30))
    }

    fn project(&self, id: i64) -> Result<Project, FenrirError> {
        self.registry.lock().unwrap().get(id)?.ok_or_else(|| FenrirError::Invalid(format!("no project {id}")))
    }

    fn spawn(
        &self,
        project: &Project,
        id: i64,
        cols: u16,
        rows: u16,
        listener: Arc<dyn OutputListener>,
    ) -> Result<Session, FenrirError> {
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
        let mut cmd = command::build_command(project, &shell, &self.ssh, id);
        cmd.env.push(("FENRIR_SESSION".into(), id.to_string()));
        cmd.env.push(("FENRIR_HOME".into(), self.data_dir.to_string_lossy().into_owned()));
        if let Some(host) = &project.host {
            self.remote_tails.ensure(host);
        }
        Session::spawn(&cmd, cols, rows, listener)
    }
}
