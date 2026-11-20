use crate::registry::Project;
use crate::ssh::{quote, Ssh};

/// What to spawn inside a PTY for a project.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionCommand {
    pub program: String,
    pub args: Vec<String>,
    /// Working directory; `None` for remote (cwd is set by tmux on the host).
    pub cwd: Option<String>,
    /// Extra environment for the child (e.g. FENRIR_SESSION).
    pub env: Vec<(String, String)>,
}

/// Local → login shell in the repo dir. Remote → ssh straight into a login shell in the repo dir,
/// as Termius does; the user runs tmux there themselves. FENRIR_SESSION is set on the host side
/// because ssh does not carry the local environment.
pub fn build_command(p: &Project, shell: &str, ssh: &Ssh, session: i64) -> SessionCommand {
    match &p.host {
        Some(host) => {
            // Own connection per terminal, as Termius does: window-size changes did not reach the host
            // through the shared ControlMaster connection (measured: host stayed at the spawn size).
            // ssh keeps the first value of an option, so these override the shared-connection defaults.
            let mut args: Vec<String> = ["-t", "-o", "ControlMaster=no", "-o", "ControlPath=none"].map(String::from).to_vec();
            args.extend(ssh.base_args());
            args.extend(["--".into(), host.clone()]);
            args.push(format!("cd {} 2>/dev/null; export FENRIR_SESSION={session}; exec \"$SHELL\" -l", quote(&p.path)));
            SessionCommand { program: "ssh".into(), args, cwd: None, env: vec![] }
        }
        None => SessionCommand {
            program: shell.into(),
            args: vec!["-l".into()],
            cwd: Some(p.path.clone()),
            env: vec![],
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn proj(host: Option<&str>) -> Project {
        Project { id: 1, name: "my.app v2".into(), path: "/srv/it's".into(), host: host.map(Into::into) }
    }

    fn ssh() -> Ssh {
        Ssh::new(std::path::Path::new("/tmp/fenrir-test-home"))
    }

    #[test]
    fn local_runs_login_shell_in_repo() {
        let c = build_command(&proj(None), "/bin/zsh", &ssh(), 1);
        assert_eq!(c.program, "/bin/zsh");
        assert_eq!(c.args, ["-l"]);
        assert_eq!(c.cwd.as_deref(), Some("/srv/it's"));
    }

    #[test]
    fn organization_ssh_opens_a_login_shell_in_the_repo() {
        let s = ssh();
        let c = build_command(&proj(Some("dev1")), "/bin/zsh", &s, 42);
        assert_eq!(c.program, "ssh");
        assert_eq!(c.args[..5], ["-t", "-o", "ControlMaster=no", "-o", "ControlPath=none"]);
        let n = s.base_args().len();
        assert_eq!(c.args[5..5 + n], s.base_args()[..]);
        assert_eq!(
            c.args[5 + n..],
            ["--", "dev1", "cd '/srv/it'\\''s' 2>/dev/null; export FENRIR_SESSION=42; exec \"$SHELL\" -l"]
        );
        assert_eq!(c.cwd, None);
    }
}
