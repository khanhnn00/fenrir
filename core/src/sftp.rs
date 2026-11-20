//! Directory browsing and basic file operations for the file transfer view, on this Mac and over ssh.
use crate::error::FenrirError;
use crate::ssh::quote;

/// One row of a folder listing in the transfer view.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SftpEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    /// Seconds since the epoch.
    pub modified: i64,
}

pub fn join(dir: &str, name: &str) -> String {
    format!("{}/{name}", dir.trim_end_matches('/'))
}

pub fn base_name(path: &str) -> &str {
    path.trim_end_matches('/').rsplit('/').next().unwrap_or(path)
}

pub fn parent(path: &str) -> String {
    match path.trim_end_matches('/').rsplit_once('/') {
        Some(("", _)) | None => "/".into(),
        Some((p, _)) => p.into(),
    }
}

/// A new name must be one plain path component.
pub fn validate_name(name: &str) -> Result<(), FenrirError> {
    if name.trim().is_empty() || name == "." || name == ".." || name.contains(['/', '\0', '\n']) {
        return Err(FenrirError::Invalid(format!("invalid name: {name:?}")));
    }
    Ok(())
}

/// `a.txt` -> `a (2).txt`; names without an extension (or dotfiles) get the number appended.
pub fn numbered_name(name: &str, n: u32) -> String {
    match name.rfind('.') {
        Some(i) if i > 0 => format!("{} ({n}){}", &name[..i], &name[i..]),
        _ => format!("{name} ({n})"),
    }
}

/// The first of `name`, `name (1)`, `name (2)`… that `taken` does not report.
pub fn unique_name(name: &str, taken: &dyn Fn(&str) -> bool) -> String {
    if !taken(name) {
        return name.to_string();
    }
    (1..).map(|n| numbered_name(name, n)).find(|c| !taken(c)).unwrap()
}

fn invalid<E: std::fmt::Display>(e: E) -> FenrirError {
    FenrirError::Invalid(e.to_string())
}

fn secs(t: std::io::Result<std::time::SystemTime>) -> i64 {
    t.ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_secs() as i64)
}

/// Children of a local folder, folders first then by name; symlinks show what they point at.
pub fn list_local(dir: &str) -> Result<Vec<SftpEntry>, FenrirError> {
    let mut v = Vec::new();
    for e in std::fs::read_dir(dir).map_err(invalid)?.flatten() {
        let path = e.path();
        let Ok(md) = std::fs::metadata(&path).or_else(|_| e.metadata()) else { continue };
        v.push(SftpEntry {
            name: e.file_name().to_string_lossy().into_owned(),
            path: path.to_string_lossy().into_owned(),
            is_dir: md.is_dir(),
            size: if md.is_dir() { 0 } else { md.len() },
            modified: secs(md.modified()),
        });
    }
    sort_entries(&mut v);
    Ok(v)
}

pub fn sort_entries(v: &mut [SftpEntry]) {
    v.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
}

pub fn local_mkdir(dir: &str, name: &str) -> Result<String, FenrirError> {
    validate_name(name)?;
    let p = join(dir, name);
    std::fs::create_dir(&p).map_err(invalid)?;
    Ok(p)
}

pub fn local_rename(path: &str, new_name: &str) -> Result<String, FenrirError> {
    validate_name(new_name)?;
    let to = join(&parent(path), new_name);
    if std::fs::symlink_metadata(&to).is_ok() {
        return Err(FenrirError::Invalid(format!("{new_name} already exists")));
    }
    std::fs::rename(path, &to).map_err(invalid)?;
    Ok(to)
}

pub fn local_delete(path: &str) -> Result<(), FenrirError> {
    if path.trim_end_matches('/').is_empty() {
        return Err(FenrirError::Invalid("refusing to delete the root folder".into()));
    }
    let md = std::fs::symlink_metadata(path).map_err(invalid)?;
    if md.is_dir() { std::fs::remove_dir_all(path) } else { std::fs::remove_file(path) }.map_err(invalid)
}

/// Remote shell line printing `type<TAB>size<TAB>mtime<TAB>name` for each child of `dir`
/// (GNU find; BSD stat as the fallback).
pub fn remote_list_cmd(dir: &str) -> String {
    format!(
        "cd {} 2>/dev/null || {{ echo 'cannot open folder' >&2; exit 3; }}; \
         if find . -maxdepth 0 -printf '' 2>/dev/null; then \
         find . -mindepth 1 -maxdepth 1 -printf '%Y\\t%s\\t%T@\\t%f\\n' 2>/dev/null; \
         else for f in .[!.]* ..?* *; do [ -e \"$f\" ] || [ -L \"$f\" ] || continue; \
         stat -L -f '%HT%t%z%t%m%t%N' \"$f\" 2>/dev/null; done; fi; true",
        quote(dir)
    )
}

pub fn parse_remote_list(dir: &str, out: &str) -> Vec<SftpEntry> {
    let mut v: Vec<SftpEntry> = out
        .lines()
        .filter_map(|l| {
            let mut f = l.splitn(4, '\t');
            let (kind, size, mtime, name) = (f.next()?, f.next()?, f.next()?, f.next()?);
            let is_dir = kind == "d" || kind == "Directory";
            Some(SftpEntry {
                name: name.to_string(),
                path: join(dir, name),
                is_dir,
                size: if is_dir { 0 } else { size.parse().unwrap_or(0) },
                modified: mtime.parse::<f64>().map_or(0, |m| m as i64),
            })
        })
        .collect();
    sort_entries(&mut v);
    v
}

pub fn remote_mkdir_cmd(dir: &str, name: &str) -> String {
    format!("mkdir -- {}", quote(&join(dir, name)))
}

pub fn remote_rename_cmd(path: &str, new_name: &str) -> String {
    let to = join(&parent(path), new_name);
    format!(
        "if [ -e {t} ] || [ -L {t} ]; then echo 'that name already exists' >&2; exit 1; fi; mv -- {} {t}",
        quote(path),
        t = quote(&to)
    )
}

pub fn remote_delete_cmd(path: &str) -> Result<String, FenrirError> {
    if path.trim_end_matches('/').is_empty() {
        return Err(FenrirError::Invalid("refusing to delete the root folder".into()));
    }
    Ok(format!("rm -rf -- {}", quote(path)))
}

/// Prints `d` when `path` is a folder, `1` when something else is there (dangling links count), else `0`.
pub fn remote_probe_cmd(path: &str) -> String {
    let p = quote(path);
    format!("if [ -d {p} ]; then echo d; elif [ -e {p} ] || [ -L {p} ]; then echo 1; else echo 0; fi")
}

/// Prints the size in bytes of every file under `path` (or of `path` itself when it is a file).
pub fn remote_sizes_cmd(path: &str) -> String {
    let p = quote(path);
    format!(
        "if find / -maxdepth 0 -printf '' 2>/dev/null; then find {p} -type f -printf '%s\\n' 2>/dev/null; \
         else find {p} -type f -exec stat -f %z {{}} + 2>/dev/null; fi; true"
    )
}

pub fn sum_sizes(out: &str) -> u64 {
    out.lines().filter_map(|l| l.trim().parse::<u64>().ok()).sum()
}

/// Sum of file sizes under a local path.
pub fn local_size(path: &std::path::Path) -> u64 {
    let Ok(md) = std::fs::symlink_metadata(path) else { return 0 };
    if md.is_file() {
        return md.len();
    }
    if !md.is_dir() {
        return 0;
    }
    std::fs::read_dir(path).map_or(0, |rd| rd.flatten().map(|e| local_size(&e.path())).sum())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    #[test]
    fn path_helpers() {
        assert_eq!(join("/a/b/", "c"), "/a/b/c");
        assert_eq!(join("/", "c"), "/c");
        assert_eq!(parent("/a/b/c"), "/a/b");
        assert_eq!(parent("/a"), "/");
        assert_eq!(base_name("/a/b/"), "b");
    }

    #[test]
    fn names_are_validated_and_numbered() {
        for bad in ["", " ", ".", "..", "a/b", "a\nb"] {
            assert!(validate_name(bad).is_err(), "{bad:?}");
        }
        assert!(validate_name("ok name.txt").is_ok());
        assert_eq!(numbered_name("report.pdf", 2), "report (2).pdf");
        assert_eq!(numbered_name("archive.tar.gz", 1), "archive.tar (1).gz");
        assert_eq!(numbered_name(".bashrc", 1), ".bashrc (1)");
        assert_eq!(numbered_name("dir", 3), "dir (3)");
        let taken = ["a.txt", "a (1).txt"];
        assert_eq!(unique_name("a.txt", &|n| taken.contains(&n)), "a (2).txt");
        assert_eq!(unique_name("b.txt", &|n| taken.contains(&n)), "b.txt");
    }

    #[test]
    fn parses_gnu_and_bsd_listings() {
        let gnu = "f\t12\t1731700000.1234567890\tb.txt\nd\t4096\t1731700001.0\tsrc\nf\t0\t1.5\tA file.md\n";
        let v = parse_remote_list("/srv/", gnu);
        let names: Vec<_> = v.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, ["src", "A file.md", "b.txt"]);
        assert_eq!(v[0].path, "/srv/src");
        assert!(v[0].is_dir && v[0].size == 0);
        assert_eq!((v[2].size, v[2].modified), (12, 1731700000));
        let bsd = parse_remote_list("/x", "Directory\t96\t1731700000\tdocs\nRegular File\t7\t1731700000\ta.md\n");
        assert!(bsd[0].is_dir && !bsd[1].is_dir && bsd[1].size == 7);
    }

    #[test]
    fn commands_are_quoted_and_guarded() {
        assert_eq!(remote_mkdir_cmd("/a b", "it's"), "mkdir -- '/a b/it'\\''s'");
        assert!(remote_rename_cmd("/a/x", "y").contains("mv -- '/a/x' '/a/y'"));
        assert!(remote_delete_cmd("/").is_err());
        assert_eq!(remote_delete_cmd("/a/b c").unwrap(), "rm -rf -- '/a/b c'");
        assert_eq!(sum_sizes("10\n20\n\nx\n5\n"), 35);
    }

    fn sh(cmd: &str) -> String {
        let o = Command::new("sh").args(["-c", cmd]).output().unwrap();
        String::from_utf8_lossy(&o.stdout).into_owned()
    }

    #[test]
    fn remote_scripts_behave_in_a_shell() {
        let d = tempfile::tempdir().unwrap();
        let root = d.path().join("it's here");
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::write(root.join("a.txt"), "hello").unwrap();
        std::fs::write(root.join(".hid"), "xx").unwrap();
        std::fs::write(root.join("sub/b.bin"), vec![0u8; 100]).unwrap();
        let dir = root.to_str().unwrap();
        let v = parse_remote_list(dir, &sh(&remote_list_cmd(dir)));
        let names: Vec<_> = v.iter().map(|e| (e.name.as_str(), e.is_dir, e.size)).collect();
        assert_eq!(names, [("sub", true, 0), (".hid", false, 2), ("a.txt", false, 5)]);
        assert!(v[2].modified > 1_600_000_000);
        assert_eq!(sum_sizes(&sh(&remote_sizes_cmd(dir))), 107);
        assert_eq!(sum_sizes(&sh(&remote_sizes_cmd(&format!("{dir}/a.txt")))), 5);
        assert_eq!(sh(&remote_probe_cmd(dir)).trim(), "d");
        assert_eq!(sh(&remote_probe_cmd(&format!("{dir}/a.txt"))).trim(), "1");
        assert_eq!(sh(&remote_probe_cmd(&format!("{dir}/nope"))).trim(), "0");
        sh(&remote_mkdir_cmd(dir, "new dir"));
        assert!(root.join("new dir").is_dir());
        sh(&remote_rename_cmd(&format!("{dir}/a.txt"), "c.txt"));
        assert!(root.join("c.txt").exists() && !root.join("a.txt").exists());
        let clash = Command::new("sh").args(["-c", &remote_rename_cmd(&format!("{dir}/c.txt"), "sub")]).output().unwrap();
        assert!(!clash.status.success() && root.join("c.txt").exists());
        sh(&remote_delete_cmd(&format!("{dir}/sub")).unwrap());
        assert!(!root.join("sub").exists());
        assert_eq!(sh(&remote_list_cmd(&format!("{dir}/nope"))), "");
    }

    #[test]
    fn local_listing_and_ops() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().to_str().unwrap();
        std::fs::write(d.path().join("z.txt"), "abc").unwrap();
        local_mkdir(p, "Docs").unwrap();
        assert!(local_mkdir(p, "a/b").is_err());
        let v = list_local(p).unwrap();
        assert_eq!((v[0].name.as_str(), v[0].is_dir), ("Docs", true));
        assert_eq!((v[1].name.as_str(), v[1].size), ("z.txt", 3));
        let moved = local_rename(&v[1].path, "y.txt").unwrap();
        assert!(moved.ends_with("/y.txt") && local_rename(&moved, "Docs").is_err());
        local_delete(&moved).unwrap();
        local_delete(&join(p, "Docs")).unwrap();
        assert!(list_local(p).unwrap().is_empty());
        assert!(local_delete("/").is_err());
    }
}
