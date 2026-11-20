/// A TCP port listening on a remote host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ListeningPort {
    pub port: u16,
    /// Program name when the host reveals it, else empty.
    pub process: String,
}

/// Lists listening TCP sockets with `ss`, falling back to `netstat`.
pub const DETECT_CMD: &str = "ss -H -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null";

/// Parses `ss -H -ltnp` or `netstat -ltnp` output; one entry per port, sorted, port 22 left out.
pub fn parse_listening(out: &str) -> Vec<ListeningPort> {
    let mut ports: Vec<ListeningPort> = Vec::new();
    for line in out.lines() {
        let cols: Vec<&str> = line.split_whitespace().collect();
        // ss: State Recv-Q Send-Q Local Peer [Process]; netstat: Proto Recv-Q Send-Q Local Foreign State [PID/Program]
        let (local, rest) = match cols.first() {
            Some(c) if c.starts_with("tcp") => (cols.get(3), cols.get(6..).unwrap_or(&[])),
            Some(&"LISTEN") => (cols.get(3), cols.get(5..).unwrap_or(&[])),
            _ => continue,
        };
        let Some(port) = local.and_then(|l| l.rsplit(':').next()).and_then(|p| p.parse::<u16>().ok()) else { continue };
        if port == 22 || ports.iter().any(|p| p.port == port) {
            continue;
        }
        ports.push(ListeningPort { port, process: process_name(&rest.join(" ")) });
    }
    ports.sort_by_key(|p| p.port);
    ports
}

fn process_name(s: &str) -> String {
    if let Some(i) = s.find("((\"") {
        return s[i + 3..].split('"').next().unwrap_or("").to_string();
    }
    // netstat: `1234/node`
    s.split_whitespace()
        .find_map(|w| w.split_once('/').filter(|(pid, _)| !pid.is_empty() && pid.chars().all(|c| c.is_ascii_digit())).map(|(_, n)| n.to_string()))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ss() {
        let out = "LISTEN 0 4096 127.0.0.1:52401 0.0.0.0:* users:((\"node\",pid=12,fd=19))\n\
                   LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n\
                   LISTEN 0 511 *:3000 *:* users:((\"next-server\",pid=99,fd=20))\n\
                   LISTEN 0 128 [::]:3000 [::]:*\n\
                   LISTEN 0 5 [::1]:8080 [::]:*\n";
        assert_eq!(
            parse_listening(out),
            vec![
                ListeningPort { port: 3000, process: "next-server".into() },
                ListeningPort { port: 8080, process: String::new() },
                ListeningPort { port: 52401, process: "node".into() },
            ]
        );
    }

    #[test]
    fn parses_netstat() {
        let out = "Active Internet connections (only servers)\n\
                   Proto Recv-Q Send-Q Local Address Foreign Address State PID/Program name\n\
                   tcp 0 0 127.0.0.1:5432 0.0.0.0:* LISTEN 321/postgres\n\
                   tcp6 0 0 :::8000 :::* LISTEN -\n";
        assert_eq!(
            parse_listening(out),
            vec![ListeningPort { port: 5432, process: "postgres".into() }, ListeningPort { port: 8000, process: String::new() }]
        );
    }
}
