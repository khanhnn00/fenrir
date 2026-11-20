use ignore::WalkBuilder;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
}

/// Direct children of `dir`: .gitignore respected (also outside a git repo), `.git` hidden,
/// dotfiles shown, folders first then names case-insensitively.
pub fn list_dir(dir: &str) -> Vec<FileEntry> {
    let mut out: Vec<FileEntry> = WalkBuilder::new(dir)
        .max_depth(Some(1))
        .hidden(false)
        .require_git(false)
        .filter_entry(|e| e.file_name() != ".git")
        .build()
        .filter_map(Result::ok)
        .filter(|e| e.depth() == 1)
        .map(|e| FileEntry {
            name: e.file_name().to_string_lossy().into_owned(),
            path: e.path().to_string_lossy().into_owned(),
            is_dir: e.file_type().is_some_and(|t| t.is_dir()),
        })
        .collect();
    out.sort_by(|a, b| {
        b.is_dir.cmp(&a.is_dir).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    out
}

/// Subsequence match of `query` in `path` (case-insensitive); lower is better. Matches in the file
/// name, at word starts and in a row score best; `None` when the letters do not all appear in order.
pub fn fuzzy_score(query: &str, path: &str) -> Option<i64> {
    let q: Vec<char> = query.to_lowercase().chars().filter(|c| !c.is_whitespace()).collect();
    if q.is_empty() {
        return Some(0);
    }
    let p: Vec<char> = path.chars().collect();
    let lower: Vec<char> = path.to_lowercase().chars().collect();
    if lower.len() != p.len() {
        return None;
    }
    let name_start = p.iter().rposition(|&c| c == '/').map_or(0, |i| i + 1);
    let mut score = p.len() as i64;
    let (mut qi, mut last) = (0, None::<usize>);
    for (i, &c) in lower.iter().enumerate() {
        if qi < q.len() && c == q[qi] {
            if last == Some(i.wrapping_sub(1)) {
                score -= 8;
            }
            if i == 0 || matches!(p[i - 1], '/' | '_' | '-' | '.' | ' ') {
                score -= 6;
            }
            if i >= name_start {
                score -= 4;
            }
            last = Some(i);
            qi += 1;
        }
    }
    (qi == q.len()).then_some(score)
}

/// Best `cap` entries of `rel_paths` (relative to `root`) for `query`, best first.
pub fn rank_paths(root: &str, rel_paths: impl Iterator<Item = String>, query: &str, cap: usize) -> Vec<FileEntry> {
    let mut hits: Vec<(i64, String)> = rel_paths.filter_map(|r| fuzzy_score(query, &r).map(|s| (s, r))).collect();
    hits.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    let base = root.trim_end_matches('/');
    hits.into_iter()
        .take(cap)
        .map(|(_, r)| FileEntry {
            name: r.rsplit('/').next().unwrap_or(&r).to_string(),
            path: format!("{base}/{r}"),
            is_dir: false,
        })
        .collect()
}

/// Files under `root` (.gitignore respected, `.git` hidden) whose relative path fuzzy-matches `query`.
pub fn find_files(root: &str, query: &str, cap: usize) -> Vec<FileEntry> {
    let rels = WalkBuilder::new(root)
        .hidden(false)
        .require_git(false)
        .filter_entry(|e| e.file_name() != ".git")
        .build()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_some_and(|t| t.is_file()))
        .filter_map(|e| e.path().strip_prefix(root).ok().map(|p| p.to_string_lossy().into_owned()));
    rank_paths(root, rels, query, cap)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn lists_sorted_hides_git_and_ignored() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path();
        fs::create_dir_all(p.join(".git")).unwrap();
        fs::create_dir_all(p.join("src")).unwrap();
        fs::create_dir_all(p.join("target")).unwrap();
        fs::write(p.join(".gitignore"), "target\n*.log\n").unwrap();
        fs::write(p.join("b.md"), "").unwrap();
        fs::write(p.join("A.md"), "").unwrap();
        fs::write(p.join("x.log"), "").unwrap();
        let names: Vec<_> = list_dir(p.to_str().unwrap()).into_iter().map(|e| e.name).collect();
        assert_eq!(names, ["src", ".gitignore", "A.md", "b.md"]);
    }

    #[test]
    fn finds_files_fuzzily_and_ranks_names_first() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path();
        fs::create_dir_all(p.join("src/deep")).unwrap();
        fs::create_dir_all(p.join(".git")).unwrap();
        fs::create_dir_all(p.join("target")).unwrap();
        fs::write(p.join(".gitignore"), "target\n").unwrap();
        for f in ["src/session.rs", "src/deep/other.rs", "README.md", "target/session.rs", ".git/session"] {
            fs::write(p.join(f), "").unwrap();
        }
        let root = p.to_str().unwrap();
        let rel = |q: &str| -> Vec<String> {
            find_files(root, q, 10).into_iter().map(|e| e.path[root.len() + 1..].to_string()).collect()
        };
        assert_eq!(rel("sess"), ["src/session.rs"]);
        assert_eq!(rel("srcses"), ["src/session.rs"]);
        assert_eq!(rel("rdm"), ["README.md"]);
        assert!(rel("zzz").is_empty());
        assert_eq!(find_files(root, "rs", 1).len(), 1);
        assert_eq!(rel("").len(), 4);
    }
}
