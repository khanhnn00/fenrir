//! Port forwards from a remote host to this Mac. Each forward is one `ssh -N -L` child with its own
//! connection, watched by a thread that restarts it when the link drops. Rows persist per host and
//! come back through `restore`.
use crate::error::FenrirError;
use crate::ssh::Ssh;
use rusqlite::{params, Connection};
use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::Path;
use std::process::{Child, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ForwardStatus {
    Starting,
    Active,
    Reconnecting,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PortForward {
    pub id: i64,
    pub host: String,
    pub remote_port: u16,
    pub local_port: u16,
    pub status: ForwardStatus,
    /// Why it is not active (last ssh error, port in use), else empty.
    pub detail: String,
}

struct Live {
    host: String,
    remote: u16,
    local: u16,
    state: Arc<Mutex<(ForwardStatus, String)>>,
    stop: Arc<AtomicBool>,
    child: Arc<Mutex<Option<Child>>>,
}

pub struct Forwards {
    ssh: Ssh,
    db: Mutex<Connection>,
    live: Mutex<HashMap<i64, Live>>,
}

fn port_free(port: u16) -> bool {
    TcpListener::bind(("127.0.0.1", port)).is_ok()
}

fn in_use_message(port: u16, taken: &[u16]) -> String {
    let next = (port.saturating_add(1)..=port.saturating_add(200)).find(|p| !taken.contains(p) && port_free(*p));
    match next {
        Some(n) => format!("Local port {port} is in use. Try {n}."),
        None => format!("Local port {port} is in use."),
    }
}

/// Waits up to `d`, returning early (true) when `stop` is set.
fn nap(stop: &AtomicBool, d: Duration) -> bool {
    let end = Instant::now() + d;
    while Instant::now() < end {
        if stop.load(Ordering::Relaxed) {
            return true;
        }
        thread::sleep(Duration::from_millis(100));
    }
    stop.load(Ordering::Relaxed)
}

impl Forwards {
    pub fn new(ssh: Ssh, db_path: &Path) -> Result<Self, FenrirError> {
        Self::init(ssh, Connection::open(db_path)?)
    }

    fn init(ssh: Ssh, conn: Connection) -> Result<Self, FenrirError> {
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS forwards (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                host TEXT NOT NULL,
                remote_port INTEGER NOT NULL,
                local_port INTEGER NOT NULL,
                UNIQUE (host, remote_port)
            );",
        )?;
        Ok(Forwards { ssh, db: Mutex::new(conn), live: Mutex::new(HashMap::new()) })
    }

    #[cfg(test)]
    pub fn open_memory(ssh: Ssh) -> Result<Self, FenrirError> {
        Self::init(ssh, Connection::open_in_memory()?)
    }

    fn local_ports(&self) -> Vec<u16> {
        self.live.lock().unwrap().values().map(|l| l.local).collect()
    }

    /// Starts forwarding `remote_port` of `host` to `127.0.0.1:local_port` (same number when `None`).
    pub fn add(&self, host: &str, remote_port: u16, local_port: Option<u16>) -> Result<PortForward, FenrirError> {
        crate::ssh::check_host(host)?;
        let local = local_port.unwrap_or(remote_port);
        if remote_port == 0 || local == 0 {
            return Err(FenrirError::Invalid("port must be between 1 and 65535".into()));
        }
        let taken = self.local_ports();
        if taken.contains(&local) || !port_free(local) {
            return Err(FenrirError::Invalid(in_use_message(local, &taken)));
        }
        let db = self.db.lock().unwrap();
        if db.prepare("SELECT 1 FROM forwards WHERE host = ?1 AND remote_port = ?2")?.exists(params![host, remote_port])? {
            return Err(FenrirError::Invalid(format!("Port {remote_port} is already forwarded.")));
        }
        db.execute("INSERT INTO forwards (host, remote_port, local_port) VALUES (?1, ?2, ?3)", params![host, remote_port, local])?;
        let id = db.last_insert_rowid();
        drop(db);
        self.start(id, host, remote_port, local);
        Ok(self.snapshot(id).expect("just started"))
    }

    /// Ends the forward and forgets it.
    pub fn stop(&self, id: i64) -> Result<(), FenrirError> {
        self.db.lock().unwrap().execute("DELETE FROM forwards WHERE id = ?1", [id])?;
        if let Some(l) = self.live.lock().unwrap().remove(&id) {
            l.stop.store(true, Ordering::Relaxed);
            if let Some(c) = l.child.lock().unwrap().as_mut() {
                let _ = c.kill();
            }
        }
        Ok(())
    }

    /// Ends every ssh child (app quit); saved forwards stay saved.
    pub fn stop_all(&self) {
        for (_, l) in self.live.lock().unwrap().drain() {
            l.stop.store(true, Ordering::Relaxed);
            if let Some(c) = l.child.lock().unwrap().as_mut() {
                let _ = c.kill();
                let _ = c.wait();
            }
        }
    }

    /// Starts the saved forwards of `host` that are not running yet.
    pub fn restore(&self, host: &str) -> Result<(), FenrirError> {
        let rows: Vec<(i64, u16, u16)> = {
            let db = self.db.lock().unwrap();
            let mut stmt = db.prepare("SELECT id, remote_port, local_port FROM forwards WHERE host = ?1 ORDER BY id")?;
            let rows = stmt.query_map([host], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
            rows.collect::<Result<_, _>>()?
        };
        for (id, remote, local) in rows {
            if !self.live.lock().unwrap().contains_key(&id) {
                self.start(id, host, remote, local);
            }
        }
        Ok(())
    }

    pub fn list(&self, host: &str) -> Vec<PortForward> {
        let mut v: Vec<PortForward> = self.live.lock().unwrap().iter().filter(|(_, l)| l.host == host).map(|(id, l)| view(*id, l)).collect();
        v.sort_by_key(|f| f.id);
        v
    }

    fn snapshot(&self, id: i64) -> Option<PortForward> {
        self.live.lock().unwrap().get(&id).map(|l| view(id, l))
    }

    fn start(&self, id: i64, host: &str, remote: u16, local: u16) {
        let live = Live {
            host: host.into(),
            remote,
            local,
            state: Arc::new(Mutex::new((ForwardStatus::Starting, String::new()))),
            stop: Arc::new(AtomicBool::new(false)),
            child: Arc::new(Mutex::new(None)),
        };
        let (state, stop, child) = (live.state.clone(), live.stop.clone(), live.child.clone());
        let ssh = self.ssh.clone();
        let host = host.to_string();
        self.live.lock().unwrap().insert(id, live);
        thread::spawn(move || supervise(&ssh, &host, remote, local, &state, &stop, &child));
    }
}

fn view(id: i64, l: &Live) -> PortForward {
    let (status, detail) = l.state.lock().unwrap().clone();
    PortForward { id, host: l.host.clone(), remote_port: l.remote, local_port: l.local, status, detail }
}

fn supervise(ssh: &Ssh, host: &str, remote: u16, local: u16, state: &Mutex<(ForwardStatus, String)>, stop: &AtomicBool, slot: &Mutex<Option<Child>>) {
    let set = |s: ForwardStatus, d: String| *state.lock().unwrap() = (s, d);
    let mut retry = false;
    while !stop.load(Ordering::Relaxed) {
        if !port_free(local) {
            set(ForwardStatus::Failed, in_use_message(local, &[]));
            if nap(stop, Duration::from_secs(5)) {
                return;
            }
            continue;
        }
        set(if retry { ForwardStatus::Reconnecting } else { ForwardStatus::Starting }, String::new());
        let spawned = ssh.forward_command(host, local, remote).and_then(|mut c| {
            c.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped()).spawn().map_err(|e| FenrirError::Network(e.to_string()))
        });
        let mut child = match spawned {
            Ok(c) => c,
            Err(e) => {
                set(ForwardStatus::Failed, e.message().to_string());
                if nap(stop, Duration::from_secs(5)) {
                    return;
                }
                continue;
            }
        };
        let last_err = Arc::new(Mutex::new(String::new()));
        if let Some(err) = child.stderr.take() {
            let last = last_err.clone();
            thread::spawn(move || {
                for line in BufReader::new(err).lines().map_while(Result::ok) {
                    if !line.trim().is_empty() {
                        *last.lock().unwrap() = line.trim().to_string();
                    }
                }
            });
        }
        *slot.lock().unwrap() = Some(child);
        let addr = SocketAddr::from(([127, 0, 0, 1], local));
        let mut active = false;
        loop {
            if stop.load(Ordering::Relaxed) {
                if let Some(mut c) = slot.lock().unwrap().take() {
                    let _ = c.kill();
                    let _ = c.wait();
                }
                return;
            }
            let exited = slot.lock().unwrap().as_mut().is_some_and(|c| matches!(c.try_wait(), Ok(Some(_)) | Err(_)));
            if exited {
                break;
            }
            if !active && TcpStream::connect_timeout(&addr, Duration::from_millis(150)).is_ok() {
                active = true;
                set(ForwardStatus::Active, String::new());
            }
            thread::sleep(Duration::from_millis(250));
        }
        slot.lock().unwrap().take();
        thread::sleep(Duration::from_millis(100)); // let the stderr reader drain
        let why = last_err.lock().unwrap().clone();
        set(ForwardStatus::Reconnecting, why);
        retry = true;
        if nap(stop, Duration::from_secs(3)) {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn fake(dir: &Path, body: &str) -> Ssh {
        let bin = dir.join("ssh");
        std::fs::write(&bin, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        Ssh::new(&dir.join("data")).with_bin(bin)
    }

    fn wait_status(f: &Forwards, host: &str, want: ForwardStatus) -> PortForward {
        let end = Instant::now() + Duration::from_secs(10);
        loop {
            let p = f.list(host).remove(0);
            if p.status == want {
                return p;
            }
            assert!(Instant::now() < end, "still {:?}", p);
            thread::sleep(Duration::from_millis(50));
        }
    }

    #[test]
    fn busy_local_port_is_reported_with_a_free_suggestion() {
        let tmp = tempfile::tempdir().unwrap();
        let f = Forwards::open_memory(fake(tmp.path(), "sleep 30")).unwrap();
        let held = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = held.local_addr().unwrap().port();
        let e = f.add("box", 8080, Some(port)).unwrap_err();
        assert!(e.message().starts_with(&format!("Local port {port} is in use. Try ")), "{}", e.message());
        assert!(f.list("box").is_empty());
    }

    #[test]
    fn dropped_link_shows_reconnecting_with_the_ssh_error_and_stop_forgets_it() {
        let tmp = tempfile::tempdir().unwrap();
        let f = Forwards::open_memory(fake(tmp.path(), "echo 'ssh: Could not resolve hostname' >&2; exit 255")).unwrap();
        let free = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let p = f.add("box", 8080, Some(free)).unwrap();
        assert_eq!((p.remote_port, p.local_port), (8080, free));
        assert!(f.add("box", 8080, Some(free + 1)).is_err());
        let r = wait_status(&f, "box", ForwardStatus::Reconnecting);
        assert!(r.detail.contains("Could not resolve"), "{}", r.detail);
        f.stop(p.id).unwrap();
        assert!(f.list("box").is_empty());
        f.restore("box").unwrap();
        assert!(f.list("box").is_empty(), "a stopped forward is not restored");
    }

    #[test]
    fn saved_forwards_restore_and_stop_all_keeps_them() {
        let tmp = tempfile::tempdir().unwrap();
        let f = Forwards::open_memory(fake(tmp.path(), "sleep 30")).unwrap();
        let free = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        f.add("box", 9000, Some(free)).unwrap();
        f.stop_all();
        assert!(f.list("box").is_empty());
        f.restore("box").unwrap();
        let l = f.list("box");
        assert_eq!((l.len(), l[0].remote_port, l[0].local_port), (1, 9000, free));
        f.stop_all();
    }
}
