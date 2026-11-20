//! Naming a Claude conversation from outside it: what `/rename` writes to the transcript.

use crate::error::FenrirError;
use std::io::Write;
use std::path::{Path, PathBuf};

/// Directory name Claude Code uses for a cwd under `~/.claude/projects`.
pub fn project_slug(cwd: &str) -> String {
    cwd.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect()
}

/// The two transcript entries `/rename` appends: `custom-title` for Claude Code, `agent-name` for the hooks.
pub fn entries(session: &str, name: &str) -> String {
    let a = serde_json::json!({"type": "custom-title", "customTitle": name, "sessionId": session});
    let b = serde_json::json!({"type": "agent-name", "agentName": name, "sessionId": session});
    format!("{a}\n{b}\n")
}

fn valid(session: &str) -> bool {
    !session.is_empty() && session.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

fn transcript(home: &Path, cwd: &str, session: &str) -> PathBuf {
    home.join(".claude/projects").join(project_slug(cwd)).join(format!("{session}.jsonl"))
}

/// Appends the rename to a local transcript. A transcript that does not exist is left alone (false).
pub fn rename_local(home: &Path, cwd: &str, session: &str, name: &str) -> Result<bool, FenrirError> {
    if !valid(session) {
        return Err(FenrirError::Invalid("bad session id".into()));
    }
    let path = transcript(home, cwd, session);
    if !path.is_file() {
        return Ok(false);
    }
    let mut f = std::fs::OpenOptions::new().append(true).open(&path).map_err(|e| FenrirError::Invalid(e.to_string()))?;
    f.write_all(entries(session, name).as_bytes()).map_err(|e| FenrirError::Invalid(e.to_string()))?;
    Ok(true)
}

/// Shell command for the host: appends stdin to the transcript when it exists.
pub fn remote_cmd(cwd: &str, session: &str) -> Result<String, FenrirError> {
    if !valid(session) {
        return Err(FenrirError::Invalid("bad session id".into()));
    }
    Ok(format!(
        "f=\"$HOME/.claude/projects/{}/{session}.jsonl\"; if [ -f \"$f\" ]; then cat >> \"$f\" && echo ok; fi",
        project_slug(cwd)
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appends_both_entries_to_an_existing_transcript_only() {
        let home = std::env::temp_dir().join(format!("fenrir-title-{}", std::process::id()));
        let dir = home.join(".claude/projects/-tmp-my-proj");
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("abc-123.jsonl");
        std::fs::write(&file, "{\"type\":\"user\"}\n").unwrap();
        assert!(rename_local(&home, "/tmp/my.proj", "abc-123", "Say \"hi\"").unwrap());
        assert!(!rename_local(&home, "/tmp/my.proj", "nope", "x").unwrap());
        assert!(rename_local(&home, "/tmp/my.proj", "../x", "x").is_err());
        let text = std::fs::read_to_string(&file).unwrap();
        let lines: Vec<serde_json::Value> = text.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[1]["type"], "custom-title");
        assert_eq!(lines[1]["customTitle"], "Say \"hi\"");
        assert_eq!(lines[2]["type"], "agent-name");
        assert_eq!(lines[2]["agentName"], "Say \"hi\"");
        std::fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn remote_command_targets_the_slugged_transcript() {
        let c = remote_cmd("/home/u/a b", "s-1").unwrap();
        assert!(c.contains(".claude/projects/-home-u-a-b/s-1.jsonl"));
        assert!(remote_cmd("/x", "a;b").is_err());
    }
}
