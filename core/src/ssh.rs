use crate::error::FenrirError;
use crate::files::FileEntry;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const IGNORED_MARK: &str = "---fenrir-ignored---";

/// How Fenrir talks to remote hosts: every ssh it starts (terminal, listing, tail) shares one
/// ControlMaster socket per host under the control dir, so commands after the first are instant.
#[derive(Debug, Clone)]
pub struct Ssh {
    control_dir: PathBuf,
    bin: PathBuf,
}

/// Unix socket paths are limited to ~104 bytes; ssh appends a 40-char hash and a 17-char temp suffix.
pub fn control_dir(data_dir: &Path) -> PathBuf {
    let preferred = data_dir.join("cm");
    if preferred.to_string_lossy().len() + 1 + 40 + 17 <= 100 {
        preferred
    } else {
        PathBuf::from(format!("/tmp/fenrir-cm-{}", std::env::var("USER").unwrap_or_else(|_| "u".into())))
    }
}

fn io_err<E: std::fmt::Display>(e: E) -> FenrirError {
    FenrirError::Network(e.to_string())
}

/// A host alias must not be able to smuggle options or extra words into the ssh command line.
pub fn check_host(host: &str) -> Result<(), FenrirError> {
    let bad = host.is_empty()
        || host.starts_with('-')
        || host.chars().any(|c| c.is_whitespace() || c.is_control() || matches!(c, '\'' | '"' | '\\' | '`' | '$' | ';' | '&' | '|'));
    if bad {
        return Err(FenrirError::Invalid(format!("invalid ssh host: {host:?}")));
    }
    Ok(())
}

/// Single-quotes `s` for a POSIX shell.
pub fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

impl Ssh {
    pub fn new(data_dir: &Path) -> Self {
        let control_dir = control_dir(data_dir);
        let _ = std::fs::create_dir_all(&control_dir);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&control_dir, std::fs::Permissions::from_mode(0o700));
        }
        Ssh { control_dir, bin: PathBuf::from("ssh") }
    }

    /// The same, running `bin` instead of `ssh` (tests point it at a stand-in).
    pub fn with_bin(mut self, bin: PathBuf) -> Self {
        self.bin = bin;
        self
    }

    /// A non-interactive ssh command for `host` running `remote_cmd`, stdio left to the caller.
    pub fn command(&self, host: &str, remote_cmd: &str) -> Result<Command, FenrirError> {
        check_host(host)?;
        let mut c = Command::new(&self.bin);
        c.args(self.batch_args(host, remote_cmd));
        Ok(c)
    }

    /// Options shared by every ssh Fenrir starts: connection reuse and dead-link detection.
    pub fn base_args(&self) -> Vec<String> {
        let o = |s: String| ["-o".to_string(), s];
        [
            o("ControlMaster=auto".into()),
            o(format!("ControlPath={}/%C", self.control_dir.display())),
            o("ControlPersist=600".into()),
            o("ServerAliveInterval=15".into()),
            o("ServerAliveCountMax=3".into()),
            o("ConnectTimeout=10".into()),
        ]
        .concat()
    }

    /// A long-lived `ssh -N` carrying one local forward `127.0.0.1:local` -> `localhost:remote` on `host`.
    /// It owns its connection (no ControlMaster) so killing it closes the forward and nothing else.
    pub fn forward_command(&self, host: &str, local: u16, remote: u16) -> Result<Command, FenrirError> {
        check_host(host)?;
        let mut c = Command::new(&self.bin);
        for o in ["ExitOnForwardFailure=yes", "ControlMaster=no", "ControlPath=none", "BatchMode=yes", "ServerAliveInterval=15", "ServerAliveCountMax=3", "ConnectTimeout=10"] {
            c.args(["-o", o]);
        }
        c.args(["-N", "-L", &format!("127.0.0.1:{local}:localhost:{remote}"), "--", host]);
        Ok(c)
    }

    /// Non-interactive ssh: never prompts, fails instead.
    pub fn batch_args(&self, host: &str, remote_cmd: &str) -> Vec<String> {
        let mut a = self.base_args();
        a.extend(["-o".into(), "BatchMode=yes".into(), "--".into(), host.into(), remote_cmd.into()]);
        a
    }

    /// Runs `remote_cmd` (one shell line) on `host`, feeding `stdin`; returns stdout.
    /// Fails on a non-zero exit with the first stderr lines, or when it takes longer than `timeout`.
    pub fn run(&self, host: &str, remote_cmd: &str, stdin: Option<&[u8]>, timeout: Duration) -> Result<String, FenrirError> {
        Ok(String::from_utf8_lossy(&self.run_bytes(host, remote_cmd, stdin, timeout)?).into_owned())
    }

    /// Like [`run`] but stdout stays raw bytes, for binary files.
    pub fn run_bytes(&self, host: &str, remote_cmd: &str, stdin: Option<&[u8]>, timeout: Duration) -> Result<Vec<u8>, FenrirError> {
        let mut child = self
            .command(host, remote_cmd)?
            .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(io_err)?;
        if let (Some(data), Some(mut pipe)) = (stdin, child.stdin.take()) {
            let data = data.to_vec();
            thread::spawn(move || {
                let _ = pipe.write_all(&data);
            });
        }
        let mut out = child.stdout.take().unwrap();
        let mut err = child.stderr.take().unwrap();
        let out_t = thread::spawn(move || {
            let mut b = Vec::new();
            let _ = out.read_to_end(&mut b);
            b
        });
        let err_t = thread::spawn(move || {
            let mut b = Vec::new();
            let _ = err.read_to_end(&mut b);
            b
        });
        let end = Instant::now() + timeout;
        let status = loop {
            if let Some(s) = child.try_wait().map_err(io_err)? {
                break s;
            }
            if Instant::now() > end {
                let _ = child.kill();
                let _ = child.wait();
                return Err(FenrirError::Network(format!("ssh {host}: timed out")));
            }
            thread::sleep(Duration::from_millis(20));
        };
        let out = out_t.join().unwrap_or_default();
        let err = String::from_utf8_lossy(&err_t.join().unwrap_or_default()).into_owned();
        if !status.success() {
            let why: String = err.lines().filter(|l| !l.trim().is_empty()).take(2).collect::<Vec<_>>().join(" ");
            return Err(FenrirError::Network(format!(
                "ssh {host}: {}",
                if why.is_empty() { format!("exit {}", status.code().unwrap_or(-1)) } else { why }
            )));
        }
        Ok(out)
    }

    pub fn list_dir(&self, host: &str, dir: &str) -> Result<Vec<FileEntry>, FenrirError> {
        let out = self.run(host, &list_cmd(dir), None, Duration::from_secs(20))?;
        Ok(parse_listing(dir, &out))
    }

    /// Files under `dir` matching `query` (git's view when it is a repo, else `find`), best `cap`.
    pub fn find_files(&self, host: &str, dir: &str, query: &str, cap: usize) -> Result<Vec<FileEntry>, FenrirError> {
        let out = self.run(host, &find_cmd(dir), None, Duration::from_secs(30))?;
        Ok(crate::files::rank_paths(dir, out.lines().filter(|l| !l.is_empty()).map(String::from), query, cap))
    }

    /// First `max` bytes of a remote file.
    pub fn read_file(&self, host: &str, path: &str, max: usize) -> Result<Vec<u8>, FenrirError> {
        self.run_bytes(host, &read_cmd(path, max), None, Duration::from_secs(120))
    }

    pub fn write_file(&self, host: &str, path: &str, data: &[u8]) -> Result<(), FenrirError> {
        self.run(host, &write_cmd(path), Some(data), Duration::from_secs(30)).map(|_| ())
    }

    /// The remote login user's home directory.
    pub fn home(&self, host: &str) -> Result<String, FenrirError> {
        Ok(self.run(host, "printf %s \"$HOME\"", None, Duration::from_secs(20))?.trim().to_string())
    }
}

/// Remote shell line listing the children of `dir`, then the ones git ignores.
pub fn list_cmd(dir: &str) -> String {
    format!(
        "cd {} 2>/dev/null || exit 3; ls -1ApL 2>/dev/null | grep -vx '\\.git/'; echo '{}'; \
         ls -1ApL 2>/dev/null | grep -vx '\\.git/' | git check-ignore --stdin 2>/dev/null; true",
        quote(dir),
        IGNORED_MARK
    )
}

/// Turns [`list_cmd`] output into entries: git-ignored names dropped, folders first, names case-insensitive.
pub fn parse_listing(dir: &str, out: &str) -> Vec<FileEntry> {
    let (names, ignored) = out.split_once(IGNORED_MARK).unwrap_or((out, ""));
    let ignored: std::collections::HashSet<&str> = ignored.lines().filter(|l| !l.is_empty()).collect();
    let base = dir.trim_end_matches('/');
    let mut v: Vec<FileEntry> = names
        .lines()
        .filter(|l| !l.is_empty() && !ignored.contains(l))
        .map(|l| {
            let is_dir = l.ends_with('/');
            let name = l.trim_end_matches('/').to_string();
            FileEntry { path: format!("{base}/{name}"), name, is_dir }
        })
        .collect();
    v.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
    v
}

/// Remote shell line printing file paths relative to `dir`, at most [`FIND_LIMIT`].
pub fn find_cmd(dir: &str) -> String {
    format!(
        "cd {} 2>/dev/null || exit 3; {{ git ls-files -co --exclude-standard 2>/dev/null || \\
         find . -type f -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/target/*' 2>/dev/null | sed 's#^\\./##'; }} | head -n {FIND_LIMIT}",
        quote(dir)
    )
}

const FIND_LIMIT: usize = 50_000;

pub fn read_cmd(path: &str, max: usize) -> String {
    format!("head -c {max} -- {}", quote(path))
}

/// Writes stdin to `path` through a temp file so readers never see a half-written file.
pub fn write_cmd(path: &str) -> String {
    let dir = path.rsplit_once('/').map_or(".", |(d, _)| if d.is_empty() { "/" } else { d });
    let tmp = format!("{path}.fenrir-tmp");
    format!("mkdir -p -- {} && cat > {} && mv -f -- {} {}", quote(dir), quote(&tmp), quote(&tmp), quote(path))
}

fn strip_ci<'a>(line: &'a str, prefix: &str) -> Option<&'a str> {
    let head = line.get(..prefix.len())?;
    head.eq_ignore_ascii_case(prefix).then(|| &line[prefix.len()..])
}

/// Concrete `Host` aliases from ssh config text; wildcard and negated patterns are skipped.
pub fn parse_hosts(config: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for line in config.lines() {
        let Some(rest) = strip_ci(line.trim(), "host ") else { continue };
        for h in rest.split_whitespace() {
            if !h.contains(['*', '?', '!']) && !out.iter().any(|x| x == h) {
                out.push(h.to_string());
            }
        }
    }
    out
}

/// Paths named by `Include` lines (no glob support; `~` expanded).
pub fn parse_includes(config: &str, home: &str) -> Vec<PathBuf> {
    config
        .lines()
        .filter_map(|l| strip_ci(l.trim(), "include "))
        .flat_map(str::split_whitespace)
        .filter(|p| !p.contains(['*', '?']))
        .map(|p| match p.strip_prefix("~/") {
            Some(rest) => Path::new(home).join(rest),
            None if p.starts_with('/') => PathBuf::from(p),
            None => Path::new(home).join(".ssh").join(p),
        })
        .collect()
}

/// Aliases in `~/.ssh/config` and its plain `Include`d files.
pub fn config_hosts(home: &str) -> Vec<String> {
    let mut hosts: Vec<String> = Vec::new();
    let mut seen: Vec<PathBuf> = Vec::new();
    let mut todo = vec![Path::new(home).join(".ssh/config")];
    while let Some(p) = todo.pop() {
        if seen.contains(&p) || seen.len() > 16 {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&p) else { continue };
        seen.push(p);
        for h in parse_hosts(&text) {
            if !hosts.contains(&h) {
                hosts.push(h);
            }
        }
        todo.extend(parse_includes(&text, home));
    }
    hosts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_for_shell() {
        assert_eq!(quote("/srv/it's here"), "'/srv/it'\\''s here'");
    }

    #[test]
    fn rejects_option_like_hosts() {
        assert!(check_host("dev1").is_ok());
        assert!(check_host("coder.ws.main").is_ok());
        for bad in ["", "-oProxyCommand=x", "a b", "a;b", "a'b", "$(x)"] {
            assert!(check_host(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn control_master_args() {
        let d = tempfile::tempdir().unwrap();
        let s = Ssh::new(d.path());
        let a = s.base_args().join(" ");
        assert!(a.contains("ControlMaster=auto"));
        assert!(a.contains("ControlPersist=600"));
        assert!(a.contains(&format!("ControlPath={}/%C", control_dir(d.path()).display())));
        assert!(a.contains("ServerAliveInterval=15"));
        let b = s.batch_args("dev1", "ls");
        assert_eq!(&b[b.len() - 5..], ["-o", "BatchMode=yes", "--", "dev1", "ls"].map(String::from));
    }

    #[test]
    fn control_path_stays_under_socket_limit() {
        let long = Path::new("/var/folders/ab/cdefghijklmnopqrstuvwxyz0123456789/T/tmp.AbCdEfGhIj/home");
        let c = control_dir(long);
        assert!(c.to_string_lossy().len() + 1 + 40 + 17 <= 100, "{}", c.display());
        assert_eq!(control_dir(Path::new("/Users/me/.fenrir")), Path::new("/Users/me/.fenrir/cm"));
    }

    #[test]
    fn listing_hides_ignored_and_sorts() {
        let out = "b.md\nsrc/\n.env\nA.md\ntarget/\nnode_modules/\n---fenrir-ignored---\ntarget/\nnode_modules/\n.env\n";
        let v = parse_listing("/srv/app/", out);
        let names: Vec<_> = v.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, ["src", "A.md", "b.md"]);
        assert_eq!(v[0].path, "/srv/app/src");
        assert!(v[0].is_dir && !v[1].is_dir);
        assert_eq!(parse_listing("/x", "a\nb/\n").len(), 2);
    }

    #[test]
    fn remote_commands_are_quoted() {
        assert!(list_cmd("/srv/it's").starts_with("cd '/srv/it'\\''s' 2>/dev/null"));
        assert_eq!(read_cmd("/a b/HANDOFF.md", 100), "head -c 100 -- '/a b/HANDOFF.md'");
        assert_eq!(
            write_cmd("/srv/r/.harness/notes/x.md"),
            "mkdir -p -- '/srv/r/.harness/notes' && cat > '/srv/r/.harness/notes/x.md.fenrir-tmp' \
             && mv -f -- '/srv/r/.harness/notes/x.md.fenrir-tmp' '/srv/r/.harness/notes/x.md'"
        );
    }

    #[test]
    fn reads_hosts_and_includes() {
        let cfg = "Include ~/.orbstack/ssh/config\nHost coder.*\n  X y\nHost dev1 dev2 *.coder\n  HostName 1.2.3.4\nhost Prod\nHost !skip\nMatch host a\n";
        assert_eq!(parse_hosts(cfg), ["dev1", "dev2", "Prod"]);
        assert_eq!(parse_includes(cfg, "/h"), [PathBuf::from("/h/.orbstack/ssh/config")]);
    }

    /// Runs a remote command line through the local sh, as the host's login shell would.
    fn sh(cmd: &str, stdin: Option<&str>) -> String {
        let mut c = Command::new("sh");
        c.args(["-c", cmd]).stdin(Stdio::piped()).stdout(Stdio::piped());
        let mut child = c.spawn().unwrap();
        child.stdin.take().unwrap().write_all(stdin.unwrap_or("").as_bytes()).unwrap();
        String::from_utf8(child.wait_with_output().unwrap().stdout).unwrap()
    }

    #[test]
    fn remote_scripts_behave_in_a_shell() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("it's a repo");
        std::fs::create_dir_all(p.join("src")).unwrap();
        std::fs::create_dir_all(p.join("target")).unwrap();
        std::fs::create_dir_all(p.join(".git")).unwrap();
        std::fs::write(p.join(".gitignore"), "target\n*.log\n").unwrap();
        std::fs::write(p.join("a.log"), "").unwrap();
        std::fs::write(p.join("B.md"), "").unwrap();
        assert!(Command::new("git").args(["init", "-q"]).current_dir(&p).status().unwrap().success());
        let dir = p.to_str().unwrap();
        let names: Vec<_> = parse_listing(dir, &sh(&list_cmd(dir), None)).into_iter().map(|e| e.name).collect();
        assert_eq!(names, ["src", ".gitignore", "B.md"]);

        let file = format!("{dir}/.harness/notes/x.md");
        sh(&write_cmd(&file), Some("# hi\n"));
        assert_eq!(sh(&read_cmd(&file, 1000), None), "# hi\n");
        assert_eq!(sh(&read_cmd(&file, 3), None), "# h");
        assert!(!std::path::Path::new(&format!("{file}.fenrir-tmp")).exists());

        let found: Vec<_> = sh(&find_cmd(dir), None).lines().map(String::from).collect();
        assert!(found.contains(&"B.md".to_string()) && found.contains(&".gitignore".to_string()), "{found:?}");
        assert!(!found.iter().any(|f| f.ends_with(".log") || f.starts_with("target")), "{found:?}");
        let plain = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(plain.path().join("a/node_modules")).unwrap();
        std::fs::write(plain.path().join("a/x.txt"), "").unwrap();
        std::fs::write(plain.path().join("a/node_modules/y.txt"), "").unwrap();
        assert_eq!(sh(&find_cmd(plain.path().to_str().unwrap()), None).trim(), "a/x.txt");
    }
}
