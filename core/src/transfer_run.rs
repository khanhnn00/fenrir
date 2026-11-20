//! Moves bytes for one transfer: files stream through `cat`, folders through `tar`, both over the
//! host's ssh ControlMaster connection, so progress is counted here and cancelling kills the processes.
use crate::error::FenrirError;
use crate::sftp::{join, parent};
use crate::ssh::{quote, Ssh};
use std::io::{Read, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

pub struct Ctx<'a> {
    pub ssh: &'a Ssh,
    pub host: &'a str,
    pub cancel: &'a Arc<AtomicBool>,
}

static PARTS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Scratch name next to `dst`, unique per call so parallel transfers to one name never share it.
fn part_path(dst: &str) -> String {
    format!("{dst}.fenrir-part-{}", PARTS.fetch_add(1, Ordering::SeqCst))
}

fn net(msg: impl std::fmt::Display) -> FenrirError {
    FenrirError::Network(msg.to_string())
}

/// A child process with its stderr collected and a watcher that kills it when the transfer is cancelled.
struct Proc {
    child: Arc<Mutex<Child>>,
    err: Option<JoinHandle<String>>,
    stop: Arc<AtomicBool>,
}

impl Proc {
    fn start(mut cmd: Command, cancel: &Arc<AtomicBool>, stdin: bool, stdout: bool) -> Result<(Proc, Option<ChildStdin>, Option<ChildStdout>), FenrirError> {
        cmd.stdin(if stdin { Stdio::piped() } else { Stdio::null() })
            .stdout(if stdout { Stdio::piped() } else { Stdio::null() })
            .stderr(Stdio::piped());
        let mut child = cmd.spawn().map_err(|e| net(format!("{}: {e}", cmd.get_program().to_string_lossy())))?;
        let (i, o, mut e) = (child.stdin.take(), child.stdout.take(), child.stderr.take().unwrap());
        let err = thread::spawn(move || {
            let mut b = Vec::new();
            let _ = e.read_to_end(&mut b);
            String::from_utf8_lossy(&b).into_owned()
        });
        let child = Arc::new(Mutex::new(child));
        let stop = Arc::new(AtomicBool::new(false));
        let (c, s, flag) = (child.clone(), stop.clone(), cancel.clone());
        thread::spawn(move || {
            while !s.load(Ordering::SeqCst) {
                if flag.load(Ordering::SeqCst) {
                    let _ = c.lock().unwrap().kill();
                    return;
                }
                thread::sleep(Duration::from_millis(50));
            }
        });
        Ok((Proc { child, err: Some(err), stop }, i, o))
    }

    fn kill(&self) {
        let _ = self.child.lock().unwrap().kill();
    }

    /// Waits for exit; `Ok` when it succeeded, else the first stderr lines (or the exit status).
    fn finish(mut self) -> Result<(), String> {
        let status = loop {
            if let Ok(Some(s)) = self.child.lock().unwrap().try_wait() {
                break s;
            }
            thread::sleep(Duration::from_millis(10));
        };
        self.stop.store(true, Ordering::SeqCst);
        let err = self.err.take().and_then(|h| h.join().ok()).unwrap_or_default();
        if status.success() {
            return Ok(());
        }
        let why: String = err.lines().filter(|l| !l.trim().is_empty()).take(2).collect::<Vec<_>>().join(" ");
        Err(if why.is_empty() { format!("exit {}", status.code().unwrap_or(-1)) } else { why })
    }
}

/// Copies `r` to `w`, reporting each chunk, until EOF or cancellation.
fn pump(r: &mut dyn Read, w: &mut dyn Write, cancel: &AtomicBool, on: &mut dyn FnMut(u64)) -> Result<(), FenrirError> {
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        if cancel.load(Ordering::SeqCst) {
            return Err(net("cancelled"));
        }
        let n = r.read(&mut buf).map_err(net)?;
        if n == 0 {
            return Ok(());
        }
        w.write_all(&buf[..n]).map_err(net)?;
        on(n as u64);
    }
}

/// Ends a pipeline: with a pump error everything is killed and the first process' own message wins.
fn conclude(pumped: Result<(), FenrirError>, procs: Vec<Proc>) -> Result<(), FenrirError> {
    if pumped.is_err() {
        procs.iter().for_each(Proc::kill);
    }
    let msgs: Vec<String> = procs.into_iter().filter_map(|p| p.finish().err()).collect();
    if let Some(m) = msgs.iter().find(|m| !m.starts_with("exit")) {
        return Err(net(m));
    }
    match (pumped, msgs.first()) {
        (Err(e), _) => Err(e),
        (Ok(()), Some(m)) => Err(net(m)),
        (Ok(()), None) => Ok(()),
    }
}

/// Remote script: store stdin as `dst` only if all `size` bytes arrived and no folder is in the way.
pub fn upload_file_cmd(dst: &str, part: &str, size: u64) -> String {
    let (d, p) = (quote(dst), quote(part));
    format!(
        "cat > {p} || {{ rm -f {p}; exit 1; }}; \
         if [ \"$(wc -c < {p} | tr -d ' ')\" -ne {size} ]; then rm -f {p}; echo 'upload incomplete' >&2; exit 1; fi; \
         if [ -d {d} ]; then rm -f {p}; echo 'a folder with that name already exists' >&2; exit 1; fi; mv -f {p} {d}"
    )
}

/// Remote script: unpack a tar stream from stdin into `dst_dir`, as `dst_name` when it differs from `name`.
pub fn extract_cmd(dst_dir: &str, name: &str, dst_name: &str) -> String {
    let d = quote(dst_dir);
    if name == dst_name {
        return format!("mkdir -p -- {d} && tar -xf - -C {d}");
    }
    format!(
        "mkdir -p -- {d} && s=$(mktemp -d {}) || exit 1; tar -xf - -C \"$s\" && mv -- \"$s\"/{} {}; r=$?; rm -rf \"$s\"; exit $r",
        quote(&format!("{dst_dir}/.fenrir-stage.XXXXXX")),
        quote(name),
        quote(&join(dst_dir, dst_name))
    )
}

fn tar_create(parent: &str, name: &str) -> Command {
    let mut c = Command::new("tar");
    c.args(["-cf", "-", "-C", parent, "--", name]).env("COPYFILE_DISABLE", "1");
    c
}

pub fn upload_file(ctx: &Ctx, src: &str, dst: &str, size: u64, on: &mut dyn FnMut(u64)) -> Result<(), FenrirError> {
    let (p, stdin, _) = Proc::start(ctx.ssh.command(ctx.host, &upload_file_cmd(dst, &part_path(dst), size))?, ctx.cancel, true, false)?;
    let mut stdin = stdin.unwrap();
    let pumped = match std::fs::File::open(src) {
        Ok(f) => pump(&mut f.take(size), &mut stdin, ctx.cancel, on),
        Err(e) => Err(net(format!("{src}: {e}"))),
    };
    drop(stdin);
    conclude(pumped, vec![p])
}

pub fn upload_dir(ctx: &Ctx, src: &str, dst_dir: &str, dst_name: &str, on: &mut dyn FnMut(u64)) -> Result<(), FenrirError> {
    let name = crate::sftp::base_name(src);
    let (tar, _, out) = Proc::start(tar_create(&parent(src.trim_end_matches('/')), name), ctx.cancel, false, true)?;
    let (ssh, stdin, _) = match Proc::start(ctx.ssh.command(ctx.host, &extract_cmd(dst_dir, name, dst_name))?, ctx.cancel, true, false) {
        Ok(v) => v,
        Err(e) => {
            tar.kill();
            return Err(e);
        }
    };
    let (mut out, mut stdin) = (out.unwrap(), stdin.unwrap());
    let pumped = pump(&mut out, &mut stdin, ctx.cancel, on);
    drop(stdin);
    conclude(pumped, vec![ssh, tar])
}

pub fn download_file(ctx: &Ctx, src: &str, dst: &str, on: &mut dyn FnMut(u64)) -> Result<(), FenrirError> {
    let part = part_path(dst);
    let result = (|| {
        let mut f = std::fs::File::create(&part).map_err(|e| net(format!("{part}: {e}")))?;
        let (p, _, out) = Proc::start(ctx.ssh.command(ctx.host, &format!("cat -- {}", quote(src)))?, ctx.cancel, false, true)?;
        let pumped = pump(&mut out.unwrap(), &mut f, ctx.cancel, on);
        conclude(pumped, vec![p])?;
        if Path::new(dst).is_dir() {
            return Err(net("a folder with that name already exists"));
        }
        std::fs::rename(&part, dst).map_err(net)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&part);
    }
    result
}

pub fn download_dir(ctx: &Ctx, src: &str, dst_dir: &str, dst_name: &str, on: &mut dyn FnMut(u64)) -> Result<(), FenrirError> {
    let name = crate::sftp::base_name(src);
    std::fs::create_dir_all(dst_dir).map_err(|e| net(format!("{dst_dir}: {e}")))?;
    let stage = (name != dst_name).then(|| {
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.subsec_nanos());
        join(dst_dir, &format!(".fenrir-stage-{}-{nanos}", std::process::id()))
    });
    let into = stage.clone().unwrap_or_else(|| dst_dir.to_string());
    let result = (|| {
        std::fs::create_dir_all(&into).map_err(net)?;
        let remote = format!("tar -cf - -C {} -- {}", quote(&parent(src.trim_end_matches('/'))), quote(name));
        let (ssh, _, out) = Proc::start(ctx.ssh.command(ctx.host, &remote)?, ctx.cancel, false, true)?;
        let mut untar = Command::new("tar");
        untar.args(["-xf", "-", "-C", &into]);
        let (tar, stdin, _) = match Proc::start(untar, ctx.cancel, true, false) {
            Ok(v) => v,
            Err(e) => {
                ssh.kill();
                return Err(e);
            }
        };
        let (mut out, mut stdin) = (out.unwrap(), stdin.unwrap());
        let pumped = pump(&mut out, &mut stdin, ctx.cancel, on);
        drop(stdin);
        conclude(pumped, vec![ssh, tar])?;
        if let Some(s) = &stage {
            std::fs::rename(join(s, name), join(dst_dir, dst_name)).map_err(net)?;
        }
        Ok(())
    })();
    if let Some(s) = &stage {
        let _ = std::fs::remove_dir_all(s);
    }
    result
}

/// Writing to a killed ssh or tar must fail with an error, not end the host app with SIGPIPE
/// (Rust's own startup does this for Rust programs, but here a Swift app hosts the library).
pub fn ignore_sigpipe() {
    #[cfg(unix)]
    {
        extern "C" {
            fn signal(sig: i32, handler: usize) -> usize;
        }
        const SIGPIPE: i32 = 13;
        const SIG_IGN: usize = 1;
        // SAFETY: plain libc call with a valid signal number and SIG_IGN.
        unsafe { signal(SIGPIPE, SIG_IGN) };
    }
}
