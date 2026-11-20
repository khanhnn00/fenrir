use crate::command::SessionCommand;
use crate::error::FenrirError;
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use std::thread;

/// Implemented in Swift; receives PTY output and exit.
#[uniffi::export(with_foreign)]
pub trait OutputListener: Send + Sync {
    fn on_output(&self, data: Vec<u8>);
    /// `code` is the child's exit status (`-1` when unknown); ssh exits 255 when the connection fails.
    fn on_exit(&self, code: i32);
}

pub struct Session {
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    child: Arc<Mutex<Box<dyn Child + Send + Sync>>>,
}

fn err<E: std::fmt::Display>(e: E) -> FenrirError {
    FenrirError::Session(e.to_string())
}

fn size(cols: u16, rows: u16) -> PtySize {
    PtySize { rows, cols, pixel_width: 0, pixel_height: 0 }
}

/// Exit status once the PTY reached EOF (the child is gone or about to be).
fn exit_code(child: &Mutex<Box<dyn Child + Send + Sync>>) -> i32 {
    for _ in 0..40 {
        if let Ok(Some(st)) = child.lock().unwrap().try_wait() {
            return st.exit_code() as i32;
        }
        thread::sleep(Duration::from_millis(50));
    }
    -1
}

impl Session {
    pub fn spawn(
        cmd: &SessionCommand,
        cols: u16,
        rows: u16,
        listener: Arc<dyn OutputListener>,
    ) -> Result<Self, FenrirError> {
        let pair = native_pty_system().openpty(size(cols, rows)).map_err(err)?;
        let mut b = CommandBuilder::new(&cmd.program);
        b.args(&cmd.args);
        for (k, v) in &cmd.env {
            b.env(k, v);
        }
        if let Some(cwd) = &cmd.cwd {
            b.cwd(cwd);
        }
        b.env("TERM", "xterm-256color");
        // Fenrir started from inside a Claude Code run would otherwise mark every `claude` in its shells as a
        // child session, which turns transcript saving (and so `--resume`) off.
        for k in ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_SESSION_ATTENDED"] {
            b.env_remove(k);
        }
        let child = Arc::new(Mutex::new(pair.slave.spawn_command(b).map_err(err)?));
        drop(pair.slave);
        let mut reader = pair.master.try_clone_reader().map_err(err)?;
        let writer = pair.master.take_writer().map_err(err)?;
        let waiter = child.clone();
        thread::spawn(move || {
            let mut buf = [0u8; 8192];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => listener.on_output(buf[..n].to_vec()),
                }
            }
            listener.on_exit(exit_code(&waiter));
        });
        Ok(Session { master: pair.master, writer, child })
    }

    pub fn write(&mut self, data: &[u8]) -> Result<(), FenrirError> {
        self.writer.write_all(data).map_err(err)?;
        self.writer.flush().map_err(err)
    }

    pub fn resize(&self, cols: u16, rows: u16) -> Result<(), FenrirError> {
        self.master.resize(size(cols, rows)).map_err(err)
    }

    pub fn is_alive(&mut self) -> bool {
        matches!(self.child.lock().unwrap().try_wait(), Ok(None))
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.child.lock().unwrap().kill();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    struct Collect(Mutex<Vec<u8>>);
    impl OutputListener for Collect {
        fn on_output(&self, d: Vec<u8>) {
            self.0.lock().unwrap().extend(d);
        }
        fn on_exit(&self, _code: i32) {}
    }

    #[test]
    fn pty_runs_in_cwd_and_echoes_input() {
        let l = Arc::new(Collect(Mutex::new(vec![])));
        let cmd = SessionCommand { program: "/bin/sh".into(), args: vec![], cwd: Some("/tmp".into()), env: vec![] };
        let mut s = Session::spawn(&cmd, 80, 24, l.clone()).unwrap();
        s.write(b"pwd -P; echo fenrir_$((20+22))\n").unwrap();
        let end = Instant::now() + Duration::from_secs(5);
        loop {
            let out = String::from_utf8_lossy(&l.0.lock().unwrap()).to_string();
            if out.contains("fenrir_42") || Instant::now() > end {
                assert!(out.contains("fenrir_42"), "got {out}");
                assert!(out.contains("/tmp"), "got {out}");
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        assert!(s.is_alive());
    }

    struct Exit(Mutex<Option<i32>>);
    impl OutputListener for Exit {
        fn on_output(&self, _d: Vec<u8>) {}
        fn on_exit(&self, code: i32) {
            *self.0.lock().unwrap() = Some(code);
        }
    }

    #[test]
    fn reports_exit_code_so_ssh_drops_can_be_told_apart() {
        for want in [0, 255] {
            let l = Arc::new(Exit(Mutex::new(None)));
            let cmd = SessionCommand { program: "/bin/sh".into(), args: vec!["-c".into(), format!("exit {want}")], cwd: None, env: vec![] };
            let _s = Session::spawn(&cmd, 80, 24, l.clone()).unwrap();
            let end = Instant::now() + Duration::from_secs(5);
            while l.0.lock().unwrap().is_none() && Instant::now() < end {
                thread::sleep(Duration::from_millis(20));
            }
            assert_eq!(*l.0.lock().unwrap(), Some(want));
        }
    }
}
