//! Coder workspaces as ssh hosts: `coder list -o json` (read-only) mapped to the host names that
//! the `*.coder` entries written by `coder config-ssh` match (`<agent>.<workspace>.<owner>.coder`).

use crate::error::FenrirError;
use serde::Deserialize;
use std::process::{Command, Stdio};

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoderWorkspace {
    pub name: String,
    pub owner: String,
    /// Build status as Coder reports it: running, stopped, starting, failed, ...
    pub status: String,
    /// The ssh host name for this workspace.
    pub host: String,
}

#[derive(Deserialize)]
struct Ws {
    name: String,
    owner_name: String,
    latest_build: Build,
}

#[derive(Deserialize)]
struct Build {
    status: String,
    #[serde(default)]
    resources: Vec<Res>,
}

#[derive(Deserialize)]
struct Res {
    #[serde(default)]
    agents: Option<Vec<Agent>>,
}

#[derive(Deserialize)]
struct Agent {
    name: String,
}

/// One entry per workspace and agent, in Coder's order.
pub fn parse_list(json: &str) -> Result<Vec<CoderWorkspace>, FenrirError> {
    let all: Vec<Ws> = serde_json::from_str(json).map_err(|e| FenrirError::Invalid(format!("coder list: {e}")))?;
    let mut out = Vec::new();
    for w in all {
        let agents: Vec<&str> = w.latest_build.resources.iter().flat_map(|r| r.agents.iter().flatten()).map(|a| a.name.as_str()).collect();
        let hosts: Vec<String> = if agents.is_empty() {
            vec![format!("{}.{}.coder", w.name, w.owner_name)]
        } else {
            agents.iter().map(|a| format!("{a}.{}.{}.coder", w.name, w.owner_name)).collect()
        };
        for host in hosts {
            out.push(CoderWorkspace { name: w.name.clone(), owner: w.owner_name.clone(), status: w.latest_build.status.clone(), host });
        }
    }
    Ok(out)
}

/// Runs `coder list -o json`.
pub fn list() -> Result<Vec<CoderWorkspace>, FenrirError> {
    let path = format!("{}:/usr/local/bin:/opt/homebrew/bin", std::env::var("PATH").unwrap_or_default());
    let out = Command::new("coder")
        .args(["list", "-o", "json"])
        .env("PATH", path)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| FenrirError::Invalid(format!("coder CLI not found: {e}")))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(FenrirError::Invalid(format!("coder list failed: {}", err.trim())));
    }
    parse_list(&String::from_utf8_lossy(&out.stdout))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_workspaces_to_ssh_hosts() {
        let json = r#"[
          {"name":"ws-one","owner_name":"alice","extra":1,
           "latest_build":{"status":"running","resources":[{"agents":[{"name":"dev","status":"connected"}]},{"agents":null},{}]}},
          {"name":"old","owner_name":"alice","latest_build":{"status":"stopped","resources":[{"agents":[{"name":"a"},{"name":"b"}]}]}},
          {"name":"bare","owner_name":"me","latest_build":{"status":"starting"}}
        ]"#;
        let l = parse_list(json).unwrap();
        let hosts: Vec<&str> = l.iter().map(|w| w.host.as_str()).collect();
        assert_eq!(hosts, ["dev.ws-one.alice.coder", "a.old.alice.coder", "b.old.alice.coder", "bare.me.coder"]);
        assert_eq!(l[0].status, "running");
        assert_eq!(l[1].status, "stopped");
        assert!(parse_list("not json").is_err());
    }

    #[test]
    fn parses_the_real_cli_shape() {
        let json = r#"[{"id":"x","name":"ws-one","owner_name":"alice","latest_build":{"status":"running","transition":"start",
          "resources":[{"type":"aws_instance","agents":[{"name":"dev","status":"connected","operating_system":"linux"}]}]}}]"#;
        assert_eq!(parse_list(json).unwrap()[0].host, "dev.ws-one.alice.coder");
    }
}
