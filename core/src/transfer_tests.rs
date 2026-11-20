//! Transfers run against a stand-in `ssh` that executes the remote command line in the local sh,
//! so the real cat/tar pipelines, conflict handling, cancel and retry are exercised without a host.
use crate::sftp::join;
use crate::ssh::Ssh;
use crate::transfer::*;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::{Duration, Instant};

fn fake_ssh(dir: &Path, name: &str, prelude: &str) -> Ssh {
    let bin = dir.join(name);
    let body = format!("#!/bin/sh\n{prelude}\nwhile [ \"$1\" != \"--\" ]; do shift; done; shift; shift; exec sh -c \"$1\"\n");
    std::fs::write(&bin, body).unwrap();
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    Ssh::new(&dir.join("data")).with_bin(bin)
}

fn wait_for(t: &Transfers, id: i64, ok: impl Fn(&TransferItem) -> bool) -> TransferItem {
    let end = Instant::now() + Duration::from_secs(20);
    loop {
        let it = t.list().into_iter().find(|i| i.id == id).unwrap();
        if ok(&it) {
            return it;
        }
        assert!(Instant::now() < end, "timed out; state {:?} error {:?}", it.state, it.error);
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn finished(t: &Transfers, id: i64) -> TransferItem {
    wait_for(t, id, |i| i.state.is_final())
}

struct Env {
    _tmp: tempfile::TempDir,
    local: String,
    remote: String,
    t: Transfers,
}

fn env() -> Env {
    let tmp = tempfile::tempdir().unwrap();
    let (local, remote) = (tmp.path().join("local"), tmp.path().join("remote home"));
    std::fs::create_dir_all(&local).unwrap();
    std::fs::create_dir_all(&remote).unwrap();
    let t = Transfers::new(fake_ssh(tmp.path(), "ssh", ""));
    Env { local: local.to_str().unwrap().into(), remote: remote.to_str().unwrap().into(), t, _tmp: tmp }
}

fn tree(root: &str) -> Vec<(String, Vec<u8>)> {
    fn walk(base: &Path, dir: &Path, out: &mut Vec<(String, Vec<u8>)>) {
        for e in std::fs::read_dir(dir).unwrap().flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(base, &p, out);
            } else {
                out.push((p.strip_prefix(base).unwrap().to_string_lossy().into(), std::fs::read(&p).unwrap()));
            }
        }
    }
    let mut v = Vec::new();
    walk(Path::new(root), Path::new(root), &mut v);
    v.sort();
    v
}

fn sample_dir(root: &str) -> String {
    let d = join(root, "my folder");
    std::fs::create_dir_all(format!("{d}/sub dir/deep")).unwrap();
    std::fs::write(format!("{d}/a.txt"), "alpha").unwrap();
    std::fs::write(format!("{d}/sub dir/it's.bin"), vec![7u8; 300_000]).unwrap();
    std::fs::write(format!("{d}/sub dir/deep/z"), "").unwrap();
    d
}

#[test]
fn speed_is_a_sliding_window_that_decays() {
    let mut r = Rate::default();
    assert_eq!(r.speed(0), 0);
    r.push(0, 0);
    r.push(1000, 1000);
    r.push(2000, 3000);
    assert_eq!(r.speed(2000), 1500);
    r.push(5000, 9000);
    assert_eq!(r.speed(5000), 2000);
    assert_eq!(r.speed(20_000), 0);
}

#[test]
fn uploads_and_downloads_files_and_folders() {
    let e = env();
    let f = join(&e.local, "report v1.txt");
    std::fs::write(&f, vec![42u8; 700_000]).unwrap();
    let d = sample_dir(&e.local);

    let up_f = e.t.start("h", Direction::Upload, &f, &e.remote, ConflictPolicy::Ask).unwrap();
    let up_d = e.t.start("h", Direction::Upload, &d, &e.remote, ConflictPolicy::Ask).unwrap();
    let (a, b) = (finished(&e.t, up_f), finished(&e.t, up_d));
    assert_eq!((a.state, b.state), (TransferState::Done, TransferState::Done), "{} {}", a.error, b.error);
    assert_eq!((a.done, a.total, a.is_dir), (700_000, 700_000, false));
    assert!(b.is_dir && b.total == 300_005);
    assert_eq!(std::fs::read(join(&e.remote, "report v1.txt")).unwrap(), vec![42u8; 700_000]);
    assert_eq!(tree(&join(&e.remote, "my folder")), tree(&d));
    assert!(std::fs::read_dir(&e.remote).unwrap().flatten().all(|x| !x.file_name().to_string_lossy().contains("fenrir-part")));

    let back = join(&e.local, "back");
    std::fs::create_dir(&back).unwrap();
    let dl_f = e.t.start("h", Direction::Download, &join(&e.remote, "report v1.txt"), &back, ConflictPolicy::Ask).unwrap();
    let dl_d = e.t.start("h", Direction::Download, &join(&e.remote, "my folder"), &back, ConflictPolicy::Ask).unwrap();
    let (a, b) = (finished(&e.t, dl_f), finished(&e.t, dl_d));
    assert_eq!((a.state, b.state), (TransferState::Done, TransferState::Done), "{} {}", a.error, b.error);
    assert_eq!(std::fs::read(join(&back, "report v1.txt")).unwrap(), vec![42u8; 700_000]);
    assert_eq!(tree(&join(&back, "my folder")), tree(&d));
}

#[test]
fn conflicts_wait_for_an_answer() {
    let e = env();
    let f = join(&e.local, "a.txt");
    std::fs::write(&f, "new").unwrap();
    std::fs::write(join(&e.remote, "a.txt"), "old").unwrap();

    let ask = e.t.start("h", Direction::Upload, &f, &e.remote, ConflictPolicy::Ask).unwrap();
    wait_for(&e.t, ask, |i| i.state == TransferState::Conflict);
    e.t.resolve(ask, ConflictPolicy::Rename);
    let it = finished(&e.t, ask);
    assert_eq!(it.state, TransferState::Done);
    assert_eq!(it.dst, join(&e.remote, "a (1).txt"));
    assert_eq!(std::fs::read_to_string(join(&e.remote, "a (1).txt")).unwrap(), "new");
    assert_eq!(std::fs::read_to_string(join(&e.remote, "a.txt")).unwrap(), "old");

    let skip = e.t.start("h", Direction::Upload, &f, &e.remote, ConflictPolicy::Skip).unwrap();
    assert_eq!(finished(&e.t, skip).state, TransferState::Skipped);
    assert_eq!(std::fs::read_to_string(join(&e.remote, "a.txt")).unwrap(), "old");

    let over = e.t.start("h", Direction::Upload, &f, &e.remote, ConflictPolicy::Overwrite).unwrap();
    assert_eq!(finished(&e.t, over).state, TransferState::Done);
    assert_eq!(std::fs::read_to_string(join(&e.remote, "a.txt")).unwrap(), "new");

    // Downloads see local conflicts the same way; renamed folders land under the new name.
    let d = sample_dir(&e.remote);
    std::fs::create_dir_all(join(&e.local, "my folder")).unwrap();
    let dl = e.t.start("h", Direction::Download, &d, &e.local, ConflictPolicy::Rename).unwrap();
    let it = finished(&e.t, dl);
    assert_eq!((it.state, it.dst.clone()), (TransferState::Done, join(&e.local, "my folder (1)")), "{}", it.error);
    assert_eq!(tree(&it.dst), tree(&d));
    assert!(std::fs::read_dir(&e.local).unwrap().flatten().all(|x| !x.file_name().to_string_lossy().contains("stage")));

    let up = e.t.start("h", Direction::Upload, &join(&e.local, "my folder (1)"), &e.remote, ConflictPolicy::Rename).unwrap();
    let it = finished(&e.t, up);
    assert_eq!((it.state, it.dst), (TransferState::Done, join(&e.remote, "my folder (1)")), "{}", it.error);
}

#[test]
fn cancel_while_waiting_or_moving_data() {
    let tmp = tempfile::tempdir().unwrap();
    let (local, remote) = (tmp.path().join("l"), tmp.path().join("r"));
    std::fs::create_dir_all(&local).unwrap();
    std::fs::create_dir_all(&remote).unwrap();
    let (local, remote) = (local.to_str().unwrap().to_string(), remote.to_str().unwrap().to_string());
    let big = join(&local, "big.bin");
    std::fs::write(&big, vec![1u8; 8_000_000]).unwrap();
    std::fs::write(join(&remote, "big.bin"), "old").unwrap();

    let t = Transfers::new(fake_ssh(tmp.path(), "ssh", ""));
    let id = t.start("h", Direction::Upload, &big, &remote, ConflictPolicy::Ask).unwrap();
    wait_for(&t, id, |i| i.state == TransferState::Conflict);
    t.cancel(id);
    assert_eq!(finished(&t, id).state, TransferState::Cancelled);
    assert_eq!(std::fs::read(join(&remote, "big.bin")).unwrap(), b"old");

    // The remote end stalls before reading, so the sender blocks on a full pipe until cancelled.
    let slow = Transfers::new(fake_ssh(tmp.path(), "ssh-slow", "case \"$*\" in *'cat >'*) exec sleep 30;; esac"));
    let id = slow.start("h", Direction::Upload, &big, &remote, ConflictPolicy::Overwrite).unwrap();
    wait_for(&slow, id, |i| i.state == TransferState::Running);
    std::thread::sleep(Duration::from_millis(300));
    slow.cancel(id);
    let it = wait_for(&slow, id, |i| i.state.is_final());
    assert_eq!(it.state, TransferState::Cancelled);
    assert_eq!(std::fs::read(join(&remote, "big.bin")).unwrap(), b"old");
}

#[test]
fn failed_transfers_can_be_retried() {
    let e = env();
    let f = join(&e.local, "x.txt");
    std::fs::write(&f, "payload").unwrap();
    let into = join(&e.remote, "later");
    let id = e.t.start("h", Direction::Upload, &f, &into, ConflictPolicy::Ask).unwrap();
    let it = finished(&e.t, id);
    assert_eq!(it.state, TransferState::Failed);
    assert!(!it.error.is_empty());
    std::fs::create_dir(&into).unwrap();
    e.t.retry(id).unwrap();
    assert_eq!(finished(&e.t, id).state, TransferState::Done);
    assert_eq!(std::fs::read_to_string(join(&into, "x.txt")).unwrap(), "payload");
    assert!(e.t.retry(id).is_err());
    e.t.clear_finished();
    assert!(e.t.list().is_empty());
}

#[test]
fn rejects_bad_requests() {
    let e = env();
    assert!(e.t.start("-oProxyCommand=x", Direction::Upload, "/a", "/b", ConflictPolicy::Ask).is_err());
    assert!(e.t.start("h", Direction::Upload, "/", "/b", ConflictPolicy::Ask).is_err());
    let id = e.t.start("h", Direction::Download, &join(&e.remote, "missing"), &e.local, ConflictPolicy::Ask).unwrap();
    let it = finished(&e.t, id);
    assert_eq!(it.state, TransferState::Failed);
    assert!(it.error.contains("no longer exists"), "{}", it.error);
}

#[test]
fn one_destination_name_is_never_used_by_two_transfers_at_once() {
    let tmp = tempfile::tempdir().unwrap();
    let (local, remote) = (tmp.path().join("l"), tmp.path().join("r"));
    std::fs::create_dir_all(&local).unwrap();
    std::fs::create_dir_all(&remote).unwrap();
    let (local, remote) = (local.to_str().unwrap().to_string(), remote.to_str().unwrap().to_string());
    let f = join(&local, "same.txt");
    std::fs::write(&f, "data").unwrap();
    let t = Transfers::new(fake_ssh(tmp.path(), "ssh-slow", "case \"$*\" in *'cat >'*) exec sleep 30;; esac"));
    let first = t.start("h", Direction::Upload, &f, &remote, ConflictPolicy::Ask).unwrap();
    wait_for(&t, first, |i| i.state == TransferState::Running);
    let second = t.start("h", Direction::Upload, &f, &remote, ConflictPolicy::Ask).unwrap();
    wait_for(&t, second, |i| i.state == TransferState::Conflict);
    t.resolve(second, ConflictPolicy::Rename);
    let it = wait_for(&t, second, |i| i.state == TransferState::Running);
    assert_eq!(it.dst, join(&remote, "same (1).txt"));
    t.cancel(first);
    t.cancel(second);
    assert_eq!(finished(&t, first).state, TransferState::Cancelled);
    assert_eq!(finished(&t, second).state, TransferState::Cancelled);
}
