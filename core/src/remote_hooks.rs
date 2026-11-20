use crate::error::FenrirError;
use crate::ssh::{quote, Ssh};
use serde_json::{json, Value};
use std::time::Duration;

const HOOK_SCRIPT: &str = include_str!("../../scripts/fenrir-hook.cjs");
const NO_FILE: &str = "__FENRIR_NOFILE__";
const EVENTS: [&str; 5] = ["UserPromptSubmit", "Stop", "Notification", "SubagentStart", "SubagentStop"];

/// Run by Claude Code on the host; `$HOME` is expanded by the shell that runs hook commands.
pub const HOOK_COMMAND: &str = "node \"$HOME/.fenrir/fenrir-hook.cjs\"";

/// Settings with the Fenrir hook added to each tracked event, or `None` when it is already wired.
pub fn wire_settings(existing: Option<&str>) -> Result<Option<String>, FenrirError> {
    let mut v: Value = match existing.map(str::trim).filter(|s| !s.is_empty()) {
        Some(t) => serde_json::from_str(t).map_err(|e| FenrirError::Invalid(format!("remote settings.json is not valid JSON: {e}")))?,
        None => json!({}),
    };
    let root = v.as_object_mut().ok_or_else(|| FenrirError::Invalid("remote settings.json is not an object".into()))?;
    let hooks = root.entry("hooks").or_insert_with(|| json!({}));
    let hooks = hooks.as_object_mut().ok_or_else(|| FenrirError::Invalid("remote settings.json `hooks` is not an object".into()))?;
    let mut changed = false;
    for ev in EVENTS {
        let groups = hooks.entry(ev).or_insert_with(|| json!([]));
        let groups = groups.as_array_mut().ok_or_else(|| FenrirError::Invalid(format!("remote hooks.{ev} is not a list")))?;
        let wired = groups.iter().any(|g| {
            g["hooks"].as_array().is_some_and(|hs| hs.iter().any(|h| h["command"].as_str().is_some_and(|c| c.contains("fenrir-hook.cjs"))))
        });
        if !wired {
            groups.push(json!({"hooks": [{"type": "command", "command": HOOK_COMMAND, "timeout": 5}]}));
            changed = true;
        }
    }
    Ok(changed.then(|| serde_json::to_string_pretty(&v).unwrap() + "\n"))
}

/// True when the script is on the host and its Claude settings reference it. Read-only.
pub fn status(ssh: &Ssh, host: &str) -> Result<bool, FenrirError> {
    let cmd = "test -f \"$HOME/.fenrir/fenrir-hook.cjs\" && grep -q fenrir-hook.cjs \"$HOME/.claude/settings.json\" 2>/dev/null && echo yes; true";
    Ok(ssh.run(host, cmd, None, Duration::from_secs(20))?.trim() == "yes")
}

/// Copies the hook script to `~/.fenrir/` on the host and wires `~/.claude/settings.json`
/// (backed up first; unchanged when already wired). Returns a one-paragraph report.
pub fn install(ssh: &Ssh, host: &str, now_ms: i64) -> Result<String, FenrirError> {
    let t = Duration::from_secs(30);
    let home = ssh.home(host)?;
    if !home.starts_with('/') {
        return Err(FenrirError::Network(format!("ssh {host}: could not read $HOME")));
    }
    let has_node = ssh.run(host, "command -v node >/dev/null 2>&1 && echo yes; true", None, t)?.trim() == "yes";
    ssh.write_file(host, &format!("{home}/.fenrir/fenrir-hook.cjs"), HOOK_SCRIPT.as_bytes())?;
    let settings = format!("{home}/.claude/settings.json");
    let q = quote(&settings);
    let current = ssh.run(host, &format!("if [ -f {q} ]; then cat {q}; else printf %s {NO_FILE}; fi"), None, t)?;
    let existing = (current != NO_FILE).then_some(current.as_str());
    let mut report = String::from("hook script installed");
    match wire_settings(existing)? {
        None => report += "; settings already wired",
        Some(new) => {
            if existing.is_some() {
                let backup = format!("{settings}.bak-fenrir-{now_ms}");
                ssh.run(host, &format!("cp -p {q} {}", quote(&backup)), None, t)?;
                report += &format!("; settings backed up to {backup}");
            }
            ssh.write_file(host, &settings, new.as_bytes())?;
            report += "; settings wired";
        }
    }
    if !has_node {
        report += ". Warning: `node` was not found on the host, so the hook cannot run until it is installed";
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wires_empty_and_missing_settings() {
        for input in [None, Some(""), Some("{}")] {
            let out = wire_settings(input).unwrap().unwrap();
            let v: Value = serde_json::from_str(&out).unwrap();
            for ev in EVENTS {
                assert_eq!(v["hooks"][ev][0]["hooks"][0]["command"], HOOK_COMMAND);
            }
        }
    }

    #[test]
    fn keeps_existing_hooks_and_is_idempotent() {
        let before = r#"{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}"#;
        let once = wire_settings(Some(before)).unwrap().unwrap();
        let v: Value = serde_json::from_str(&once).unwrap();
        assert_eq!(v["model"], "x");
        assert_eq!(v["hooks"]["Stop"].as_array().unwrap().len(), 2);
        assert_eq!(v["hooks"]["Stop"][0]["hooks"][0]["command"], "echo hi");
        assert_eq!(wire_settings(Some(&once)).unwrap(), None);
    }

    #[test]
    fn rejects_unreadable_settings_instead_of_overwriting() {
        assert!(wire_settings(Some("{not json")).is_err());
        assert!(wire_settings(Some("[]")).is_err());
        assert!(wire_settings(Some(r#"{"hooks":{"Stop":{}}}"#)).is_err());
    }

    #[test]
    fn script_is_embedded() {
        assert!(HOOK_SCRIPT.contains("events.ndjson"));
    }
}
