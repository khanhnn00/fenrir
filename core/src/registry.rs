use crate::error::FenrirError;
use rusqlite::{params, Connection};
use std::path::Path;

/// A place sessions run: this Mac (`host` is `None`) or an ssh host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Machine {
    pub id: i64,
    pub name: String,
    pub host: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Project {
    pub id: i64,
    pub name: String,
    /// Local repo path, or absolute path on the host.
    pub path: String,
    /// SSH host alias of its machine; `None` means Local.
    pub host: Option<String>,
}

pub struct Registry {
    conn: Connection,
}

impl Registry {
    pub fn open(db_path: &Path) -> Result<Self, FenrirError> {
        let conn = Connection::open(db_path)?;
        Self::init(conn)
    }

    #[cfg(test)]
    pub fn open_memory() -> Result<Self, FenrirError> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self, FenrirError> {
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS projects (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                path TEXT NOT NULL,
                host TEXT
            );
            CREATE TABLE IF NOT EXISTS machines (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                host TEXT UNIQUE
            );",
        )?;
        let r = Registry { conn };
        r.migrate_groups()?;
        r.migrate_position()?;
        // Local is always first; every host a project already uses becomes a machine named after it.
        r.conn.execute(
            "INSERT INTO machines (name, host) SELECT 'Local', NULL WHERE NOT EXISTS (SELECT 1 FROM machines WHERE host IS NULL)",
            [],
        )?;
        r.conn.execute(
            "INSERT INTO machines (name, host) SELECT DISTINCT host, host FROM projects \
             WHERE host IS NOT NULL AND host NOT IN (SELECT host FROM machines WHERE host IS NOT NULL)",
            [],
        )?;
        Ok(r)
    }

    /// Databases from before machines carry a `grp` column (personal/organization) on projects;
    /// the machine is already implied by `host`, so the column goes.
    fn migrate_groups(&self) -> Result<(), FenrirError> {
        let has_grp = self.conn.prepare("SELECT 1 FROM pragma_table_info('projects') WHERE name = 'grp'")?.exists([])?;
        if has_grp {
            self.conn.execute_batch(
                "BEGIN;
                 CREATE TABLE projects_new (
                     id INTEGER PRIMARY KEY AUTOINCREMENT,
                     name TEXT NOT NULL,
                     path TEXT NOT NULL,
                     host TEXT
                 );
                 INSERT INTO projects_new (id, name, path, host) SELECT id, name, path, host FROM projects;
                 DROP TABLE projects;
                 ALTER TABLE projects_new RENAME TO projects;
                 COMMIT;",
            )?;
        }
        Ok(())
    }

    /// `pos` is the order the user dragged project cards into; new projects go last.
    fn migrate_position(&self) -> Result<(), FenrirError> {
        let has = self.conn.prepare("SELECT 1 FROM pragma_table_info('projects') WHERE name = 'pos'")?.exists([])?;
        if !has {
            self.conn.execute_batch("ALTER TABLE projects ADD COLUMN pos INTEGER NOT NULL DEFAULT 0;")?;
        }
        Ok(())
    }

    pub fn rename_project(&self, id: i64, name: &str) -> Result<(), FenrirError> {
        let name = name.trim();
        if name.is_empty() {
            return Err(FenrirError::Invalid("name is required".into()));
        }
        self.conn.execute("UPDATE projects SET name = ?1 WHERE id = ?2", params![name, id])?;
        Ok(())
    }

    /// Puts the listed projects in this order (positions 1..n); others keep theirs.
    pub fn reorder(&self, ids: &[i64]) -> Result<(), FenrirError> {
        for (i, id) in ids.iter().enumerate() {
            self.conn.execute("UPDATE projects SET pos = ?1 WHERE id = ?2", params![i as i64 + 1, id])?;
        }
        Ok(())
    }

    pub fn list_machines(&self) -> Result<Vec<Machine>, FenrirError> {
        let mut stmt = self.conn.prepare("SELECT id, name, host FROM machines ORDER BY host IS NOT NULL, id")?;
        let rows = stmt.query_map([], |r| Ok(Machine { id: r.get(0)?, name: r.get(1)?, host: r.get(2)? }))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn add_machine(&self, name: &str, host: &str) -> Result<Machine, FenrirError> {
        let (name, host) = (name.trim(), host.trim());
        crate::ssh::check_host(host)?;
        let name = if name.is_empty() { host } else { name };
        if self.conn.prepare("SELECT 1 FROM machines WHERE host = ?1")?.exists([host])? {
            return Err(FenrirError::Invalid(format!("{host} is already added")));
        }
        self.conn.execute("INSERT INTO machines (name, host) VALUES (?1, ?2)", params![name, host])?;
        Ok(Machine { id: self.conn.last_insert_rowid(), name: name.into(), host: Some(host.into()) })
    }

    pub fn rename_machine(&self, id: i64, name: &str) -> Result<(), FenrirError> {
        let name = name.trim();
        if name.is_empty() {
            return Err(FenrirError::Invalid("name is required".into()));
        }
        self.conn.execute("UPDATE machines SET name = ?1 WHERE id = ?2", params![name, id])?;
        Ok(())
    }

    /// Forgets a remote machine and its projects; Local cannot be removed. Returns the removed project ids.
    pub fn remove_machine(&self, id: i64) -> Result<Vec<i64>, FenrirError> {
        let Some(m) = self.list_machines()?.into_iter().find(|m| m.id == id) else { return Ok(vec![]) };
        let Some(host) = m.host else { return Err(FenrirError::Invalid("Local cannot be removed".into())) };
        let ids: Vec<i64> = self.list()?.into_iter().filter(|p| p.host.as_deref() == Some(&host)).map(|p| p.id).collect();
        self.conn.execute("DELETE FROM projects WHERE host = ?1", [&host])?;
        self.conn.execute("DELETE FROM machines WHERE id = ?1", [id])?;
        Ok(ids)
    }

    /// `host` of `None` (or blank) adds a local project; remote paths must be absolute.
    pub fn add(&self, name: &str, path: &str, host: Option<&str>) -> Result<Project, FenrirError> {
        let name = name.trim();
        let path = path.trim();
        let host = host.map(str::trim).filter(|h| !h.is_empty());
        if name.is_empty() || path.is_empty() {
            return Err(FenrirError::Invalid("name and path are required".into()));
        }
        if let Some(h) = host {
            crate::ssh::check_host(h)?;
            if !path.starts_with('/') {
                return Err(FenrirError::Invalid("remote path must be absolute".into()));
            }
            if !self.conn.prepare("SELECT 1 FROM machines WHERE host = ?1")?.exists([h])? {
                self.add_machine(h, h)?;
            }
        }
        self.conn.execute("INSERT INTO projects (name, path, host, pos) VALUES (?1, ?2, ?3, (SELECT COALESCE(MAX(pos), 0) + 1 FROM projects))", params![name, path, host])?;
        Ok(Project { id: self.conn.last_insert_rowid(), name: name.into(), path: path.into(), host: host.map(Into::into) })
    }

    pub fn get(&self, id: i64) -> Result<Option<Project>, FenrirError> {
        let mut stmt = self.conn.prepare("SELECT id, name, path, host FROM projects WHERE id = ?1")?;
        let mut rows = stmt.query_map([id], Self::row)?;
        Ok(rows.next().transpose()?)
    }

    pub fn list(&self) -> Result<Vec<Project>, FenrirError> {
        let mut stmt = self.conn.prepare("SELECT id, name, path, host FROM projects ORDER BY pos, name COLLATE NOCASE")?;
        let rows = stmt.query_map([], Self::row)?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn remove(&self, id: i64) -> Result<(), FenrirError> {
        self.conn.execute("DELETE FROM projects WHERE id = ?1", [id])?;
        Ok(())
    }

    fn row(r: &rusqlite::Row) -> rusqlite::Result<Project> {
        Ok(Project { id: r.get(0)?, name: r.get(1)?, path: r.get(2)?, host: r.get(3)? })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_list_get_remove() {
        let r = Registry::open_memory().unwrap();
        let a = r.add("zeta", "/tmp/z", None).unwrap();
        let b = r.add("alpha", "/srv/a", Some("dev1")).unwrap();
        assert_eq!(a.host, None);
        assert_eq!(b.host.as_deref(), Some("dev1"));
        let names: Vec<_> = r.list().unwrap().into_iter().map(|p| p.name).collect();
        assert_eq!(names, ["zeta", "alpha"], "new projects go last");
        assert_eq!(r.get(a.id).unwrap(), Some(a.clone()));
        r.remove(a.id).unwrap();
        assert_eq!(r.get(a.id).unwrap(), None);
        assert_eq!(r.list().unwrap().len(), 1);
    }

    #[test]
    fn rename_and_reorder_persist() {
        let r = Registry::open_memory().unwrap();
        let a = r.add("alpha", "/a", None).unwrap();
        let b = r.add("beta", "/b", None).unwrap();
        let c = r.add("gamma", "/c", None).unwrap();
        r.reorder(&[c.id, a.id, b.id]).unwrap();
        r.rename_project(a.id, "  Renamed ").unwrap();
        assert!(r.rename_project(a.id, " ").is_err());
        let names: Vec<_> = r.list().unwrap().into_iter().map(|p| p.name).collect();
        assert_eq!(names, ["gamma", "Renamed", "beta"]);
        let d = r.add("delta", "/d", None).unwrap();
        assert_eq!(r.list().unwrap().last().unwrap().id, d.id, "new projects go last");
    }

    #[test]
    fn project_validation() {
        let r = Registry::open_memory().unwrap();
        assert!(r.add("", "/p", None).is_err());
        assert!(r.add("x", "~/p", Some("dev1")).is_err());
        assert!(r.add("x", "/p", Some("-oProxyCommand=x")).is_err());
        assert_eq!(r.add("x", "/p", Some("  ")).unwrap().host, None, "blank host means local");
    }

    #[test]
    fn local_machine_is_first_and_permanent() {
        let r = Registry::open_memory().unwrap();
        r.add_machine("Dev box", "dev1").unwrap();
        let ms = r.list_machines().unwrap();
        assert_eq!((ms[0].name.as_str(), ms[0].host.clone()), ("Local", None));
        assert_eq!(ms[1].host.as_deref(), Some("dev1"));
        assert!(r.remove_machine(ms[0].id).is_err());
    }

    #[test]
    fn machine_rules() {
        let r = Registry::open_memory().unwrap();
        let m = r.add_machine("", "dev1").unwrap();
        assert_eq!(m.name, "dev1", "blank name falls back to the host");
        assert!(r.add_machine("again", "dev1").is_err(), "one machine per host");
        assert!(r.add_machine("bad", "-oProxyCommand=x").is_err());
        r.rename_machine(m.id, "  Dev  ").unwrap();
        assert_eq!(r.list_machines().unwrap()[1].name, "Dev");
        assert!(r.rename_machine(m.id, " ").is_err());
    }

    #[test]
    fn adding_a_project_registers_its_host() {
        let r = Registry::open_memory().unwrap();
        r.add("a", "/srv/a", Some("dev2")).unwrap();
        let ms = r.list_machines().unwrap();
        assert_eq!(ms.len(), 2);
        assert_eq!(ms[1].name, "dev2");
    }

    #[test]
    fn removing_a_machine_removes_its_projects() {
        let r = Registry::open_memory().unwrap();
        let m = r.add_machine("Dev", "dev1").unwrap();
        let keep = r.add("local", "/tmp/l", None).unwrap();
        let gone = r.add("remote", "/srv/r", Some("dev1")).unwrap();
        assert_eq!(r.remove_machine(m.id).unwrap(), vec![gone.id]);
        assert_eq!(r.list().unwrap(), vec![keep]);
        assert_eq!(r.list_machines().unwrap().len(), 1);
    }

    #[test]
    fn migrates_projects_from_personal_and_organization_groups() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("f.db");
        let old = Connection::open(&db).unwrap();
        old.execute_batch(
            "CREATE TABLE projects (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, grp TEXT NOT NULL, path TEXT NOT NULL, host TEXT);
             INSERT INTO projects (id, name, grp, path, host) VALUES (1, 'mine', 'personal', '/Users/me/mine', NULL);
             INSERT INTO projects (id, name, grp, path, host) VALUES (7, 'api', 'organization', '/srv/api', 'example-host');
             INSERT INTO projects (id, name, grp, path, host) VALUES (9, 'web', 'organization', '/srv/web', 'example-host');",
        )
        .unwrap();
        drop(old);
        let machines = |r: &Registry| r.list_machines().unwrap().into_iter().map(|m| (m.name, m.host)).collect::<Vec<_>>();
        let expected = vec![("Local".to_string(), None), ("example-host".to_string(), Some("example-host".to_string()))];
        let r = Registry::open(&db).unwrap();
        assert_eq!(r.list().unwrap().len(), 3);
        assert_eq!(r.get(1).unwrap().unwrap().host, None);
        assert_eq!(r.get(7).unwrap().unwrap().host.as_deref(), Some("example-host"));
        assert_eq!(r.get(9).unwrap().unwrap().path, "/srv/web");
        assert_eq!(machines(&r), expected);
        drop(r);
        // Opening again changes nothing.
        let r = Registry::open(&db).unwrap();
        assert_eq!(r.list().unwrap().len(), 3);
        assert_eq!(machines(&r), expected);
    }

    #[test]
    fn persists_on_disk() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("f.db");
        Registry::open(&db).unwrap().add("p", "/p", None).unwrap();
        assert_eq!(Registry::open(&db).unwrap().list().unwrap().len(), 1);
    }
}
