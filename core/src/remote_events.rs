use crate::ssh::{check_host, quote, Ssh};
use std::collections::HashSet;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

/// Remote shell line streaming new hook events. It exits (and kills tail) when ssh closes its stdin,
/// so no tail is left on the host after the app quits.
pub fn tail_cmd() -> String {
    let script = "tail -n 0 -F \"$HOME/.fenrir/events.ndjson\" 2>/dev/null & t=$!; cat >/dev/null; kill $t";
    format!("sh -c {}", quote(script))
}

/// One ssh per host following `~/.fenrir/events.ndjson` on it; lines are queued for `drain`.
pub struct RemoteTails {
    ssh: Ssh,
    started: Mutex<HashSet<String>>,
    queue: Arc<Mutex<Vec<(String, String)>>>,
}

impl RemoteTails {
    pub fn new(ssh: Ssh) -> Self {
        RemoteTails { ssh, started: Mutex::new(HashSet::new()), queue: Arc::new(Mutex::new(Vec::new())) }
    }

    /// Starts following `host` unless already doing so; restarts after connection loss.
    pub fn ensure(&self, host: &str) {
        if check_host(host).is_err() || !self.started.lock().unwrap().insert(host.to_string()) {
            return;
        }
        let (host, ssh, queue) = (host.to_string(), self.ssh.clone(), self.queue.clone());
        thread::spawn(move || loop {
            let spawned = Command::new("ssh")
                .args(ssh.batch_args(&host, &tail_cmd()))
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn();
            if let Ok(mut child) = spawned {
                let _stdin = child.stdin.take(); // dropped with the child: tail stops when we exit
                if let Some(out) = child.stdout.take() {
                    for line in BufReader::new(out).lines().map_while(Result::ok) {
                        queue.lock().unwrap().push((host.clone(), line));
                    }
                }
                let _ = child.wait();
            }
            thread::sleep(Duration::from_secs(5));
        });
    }

    /// `(host, ndjson line)` pairs received since the last call.
    pub fn drain(&self) -> Vec<(String, String)> {
        std::mem::take(&mut *self.queue.lock().unwrap())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tail_command_follows_events_file_and_cleans_up() {
        let c = tail_cmd();
        assert!(c.starts_with("sh -c 'tail -n 0 -F \"$HOME/.fenrir/events.ndjson\""));
        assert!(c.contains("cat >/dev/null; kill $t"));
    }
}
