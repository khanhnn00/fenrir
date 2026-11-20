//! The transfer queue: one background thread per item, at most [`MAX_RUNNING`] moving data at once.
use crate::error::FenrirError;
use crate::sftp::{base_name, join, unique_name};
use crate::ssh::{check_host, Ssh};
use crate::transfer_run;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const MAX_RUNNING: usize = 2;
const SPEED_WINDOW_MS: u64 = 3000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Direction {
    Upload,
    Download,
}

/// What to do when the destination already has an item with that name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConflictPolicy {
    Ask,
    Overwrite,
    Skip,
    Rename,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TransferState {
    Queued,
    /// Waiting for `resolve_conflict`.
    Conflict,
    Running,
    Done,
    Skipped,
    Failed,
    Cancelled,
}

impl TransferState {
    pub fn is_final(self) -> bool {
        matches!(self, Self::Done | Self::Skipped | Self::Failed | Self::Cancelled)
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TransferItem {
    pub id: i64,
    pub host: String,
    pub direction: Direction,
    pub name: String,
    pub src: String,
    pub dst_dir: String,
    /// Final destination path, set once any conflict is settled.
    pub dst: String,
    pub is_dir: bool,
    pub state: TransferState,
    pub done: u64,
    pub total: u64,
    /// Bytes per second over the last few seconds.
    pub speed: u64,
    pub error: String,
}

/// Bytes-per-second over a sliding window of (time, cumulative bytes) samples.
#[derive(Debug, Default)]
pub struct Rate {
    samples: VecDeque<(u64, u64)>,
}

impl Rate {
    pub fn push(&mut self, ms: u64, bytes: u64) {
        self.samples.push_back((ms, bytes));
        while self.samples.len() > 2 && ms.saturating_sub(self.samples[1].0) >= SPEED_WINDOW_MS {
            self.samples.pop_front();
        }
    }

    /// Speed as of `now_ms`; decays to 0 when no bytes arrive.
    pub fn speed(&self, now_ms: u64) -> u64 {
        let Some(&(t0, b0)) = self.samples.iter().find(|(t, _)| now_ms.saturating_sub(*t) <= SPEED_WINDOW_MS) else { return 0 };
        let b1 = self.samples.back().map_or(0, |s| s.1);
        if now_ms <= t0 { 0 } else { b1.saturating_sub(b0) * 1000 / (now_ms - t0) }
    }
}

struct Gate {
    running: Mutex<usize>,
    cv: Condvar,
}

struct Permit(Arc<Gate>);

impl Drop for Permit {
    fn drop(&mut self) {
        *self.0.running.lock().unwrap() -= 1;
        self.0.cv.notify_one();
    }
}

struct Job {
    item: Mutex<TransferItem>,
    cancel: Arc<AtomicBool>,
    policy: Mutex<ConflictPolicy>,
    decision: Mutex<Option<ConflictPolicy>>,
    cv: Condvar,
    clock: Instant,
    rate: Mutex<Rate>,
    held: Mutex<Option<String>>,
}

enum Outcome {
    Done,
    Skipped,
}

struct Shared {
    ssh: Ssh,
    gate: Arc<Gate>,
    /// Destinations already promised to a running transfer, so two items with one name cannot collide.
    reserved: Mutex<Vec<String>>,
    decide: Mutex<()>,
}

pub struct Transfers {
    shared: Arc<Shared>,
    jobs: Mutex<Vec<Arc<Job>>>,
    next: AtomicI64,
}

impl Transfers {
    pub fn new(ssh: Ssh) -> Self {
        let gate = Arc::new(Gate { running: Mutex::new(0), cv: Condvar::new() });
        Transfers { shared: Arc::new(Shared { ssh, gate, reserved: Mutex::new(Vec::new()), decide: Mutex::new(()) }), jobs: Mutex::new(Vec::new()), next: AtomicI64::new(1) }
    }

    /// Queues `src` (a path on the sending side) to go into folder `dst_dir` on the receiving side.
    pub fn start(&self, host: &str, direction: Direction, src: &str, dst_dir: &str, policy: ConflictPolicy) -> Result<i64, FenrirError> {
        check_host(host)?;
        if src.trim_end_matches('/').is_empty() || dst_dir.is_empty() {
            return Err(FenrirError::Invalid("a transfer needs a source and a destination folder".into()));
        }
        let id = self.next.fetch_add(1, Ordering::SeqCst);
        let item = TransferItem {
            id,
            host: host.into(),
            direction,
            name: base_name(src).into(),
            src: src.into(),
            dst_dir: dst_dir.into(),
            dst: String::new(),
            is_dir: false,
            state: TransferState::Queued,
            done: 0,
            total: 0,
            speed: 0,
            error: String::new(),
        };
        let job = Arc::new(Job {
            item: Mutex::new(item),
            cancel: Arc::new(AtomicBool::new(false)),
            policy: Mutex::new(policy),
            decision: Mutex::new(None),
            cv: Condvar::new(),
            clock: Instant::now(),
            rate: Mutex::new(Rate::default()),
            held: Mutex::new(None),
        });
        self.jobs.lock().unwrap().push(job.clone());
        self.spawn(job);
        Ok(id)
    }

    fn spawn(&self, job: Arc<Job>) {
        let shared = self.shared.clone();
        thread::spawn(move || shared.run(&job));
    }

    pub fn list(&self) -> Vec<TransferItem> {
        self.jobs
            .lock()
            .unwrap()
            .iter()
            .map(|j| {
                let mut it = j.item.lock().unwrap().clone();
                if it.state == TransferState::Running {
                    it.speed = j.rate.lock().unwrap().speed(j.clock.elapsed().as_millis() as u64);
                }
                it
            })
            .collect()
    }

    fn job(&self, id: i64) -> Option<Arc<Job>> {
        self.jobs.lock().unwrap().iter().find(|j| j.item.lock().unwrap().id == id).cloned()
    }

    /// Answers a transfer waiting in [`TransferState::Conflict`]; `Ask` is ignored.
    pub fn resolve(&self, id: i64, policy: ConflictPolicy) {
        if let (Some(j), true) = (self.job(id), policy != ConflictPolicy::Ask) {
            *j.decision.lock().unwrap() = Some(policy);
            j.cv.notify_all();
        }
    }

    pub fn cancel(&self, id: i64) {
        if let Some(j) = self.job(id) {
            j.cancel.store(true, Ordering::SeqCst);
            j.cv.notify_all();
        }
    }

    /// Runs a failed or cancelled transfer again; what a half-finished earlier try left is overwritten.
    pub fn retry(&self, id: i64) -> Result<(), FenrirError> {
        let job = self.job(id).ok_or_else(|| FenrirError::Invalid(format!("no transfer {id}")))?;
        {
            let mut it = job.item.lock().unwrap();
            if !matches!(it.state, TransferState::Failed | TransferState::Cancelled) {
                return Err(FenrirError::Invalid("only failed or cancelled transfers can be retried".into()));
            }
            it.state = TransferState::Queued;
            it.done = 0;
            it.speed = 0;
            it.error.clear();
        }
        job.cancel.store(false, Ordering::SeqCst);
        *job.policy.lock().unwrap() = ConflictPolicy::Overwrite;
        *job.decision.lock().unwrap() = None;
        *job.rate.lock().unwrap() = Rate::default();
        self.spawn(job);
        Ok(())
    }

    /// Forgets finished items (done, skipped, failed, cancelled).
    pub fn clear_finished(&self) {
        self.jobs.lock().unwrap().retain(|j| !j.item.lock().unwrap().state.is_final());
    }
}

impl Job {
    fn set(&self, f: impl FnOnce(&mut TransferItem)) {
        f(&mut self.item.lock().unwrap());
    }

    fn cancelled(&self) -> bool {
        self.cancel.load(Ordering::SeqCst)
    }

    /// Shows the conflict to the user and waits for the answer; `None` when cancelled meanwhile.
    fn ask(&self) -> Option<ConflictPolicy> {
        self.set(|i| i.state = TransferState::Conflict);
        let mut d = self.decision.lock().unwrap();
        loop {
            if let Some(p) = d.take() {
                return Some(p);
            }
            if self.cancelled() {
                return None;
            }
            d = self.cv.wait_timeout(d, Duration::from_millis(200)).unwrap().0;
        }
    }

    fn add_bytes(&self, n: u64) {
        let mut it = self.item.lock().unwrap();
        it.done = if it.total > 0 { (it.done + n).min(it.total) } else { it.done + n };
        self.rate.lock().unwrap().push(self.clock.elapsed().as_millis() as u64, it.done);
    }
}

impl Shared {
    fn acquire(&self, job: &Job) -> Option<Permit> {
        let mut n = self.gate.running.lock().unwrap();
        while *n >= MAX_RUNNING {
            if job.cancelled() {
                return None;
            }
            n = self.gate.cv.wait_timeout(n, Duration::from_millis(200)).unwrap().0;
        }
        *n += 1;
        Some(Permit(self.gate.clone()))
    }

    fn run(&self, job: &Arc<Job>) {
        let r = self.execute(job);
        if let Some(k) = job.held.lock().unwrap().take() {
            let mut held = self.reserved.lock().unwrap();
            if let Some(i) = held.iter().position(|h| *h == k) {
                held.remove(i);
            }
        }
        job.set(|it| {
            it.speed = 0;
            match r {
                _ if job.cancelled() => it.state = TransferState::Cancelled,
                Ok(Outcome::Done) => {
                    it.state = TransferState::Done;
                    it.done = it.total;
                }
                Ok(Outcome::Skipped) => it.state = TransferState::Skipped,
                Err(e) => {
                    it.state = TransferState::Failed;
                    it.error = e.message().to_string();
                }
            }
        });
    }

    fn remote_probe(&self, host: &str, path: &str) -> Result<char, FenrirError> {
        let out = self.ssh.run(host, &crate::sftp::remote_probe_cmd(path), None, Duration::from_secs(30))?;
        Ok(out.trim().chars().next().unwrap_or('0'))
    }

    fn execute(&self, job: &Arc<Job>) -> Result<Outcome, FenrirError> {
        let it = job.item.lock().unwrap().clone();
        let (is_dir, taken): (bool, Box<dyn Fn(&str) -> bool + '_>) = match it.direction {
            Direction::Upload => {
                let md = std::fs::metadata(&it.src).map_err(|e| FenrirError::Invalid(format!("{}: {e}", it.src)))?;
                let probe = |n: &str| self.remote_probe(&it.host, &join(&it.dst_dir, n)).map_or(false, |c| c != '0');
                (md.is_dir(), Box::new(move |n| probe(n)))
            }
            Direction::Download => {
                let kind = self.remote_probe(&it.host, &it.src)?;
                if kind == '0' {
                    return Err(FenrirError::Invalid(format!("{} no longer exists on {}", it.src, it.host)));
                }
                let dir = it.dst_dir.clone();
                (kind == 'd', Box::new(move |n| std::fs::symlink_metadata(join(&dir, n)).is_ok()))
            }
        };
        job.set(|i| i.is_dir = is_dir);
        let key = |n: &str| format!("{:?}|{}|{}", it.direction, it.host, join(&it.dst_dir, n));
        let busy = |n: &str| taken(n) || self.reserved.lock().unwrap().contains(&key(n));
        let hold = |n: &str| {
            *job.held.lock().unwrap() = Some(key(n));
            self.reserved.lock().unwrap().push(key(n));
        };
        let mut name = it.name.clone();
        let free = {
            let _one_at_a_time = self.decide.lock().unwrap();
            let free = !busy(&name);
            if free {
                hold(&name);
            }
            free
        };
        if !free {
            let policy = match *job.policy.lock().unwrap() {
                ConflictPolicy::Ask => job.ask(),
                p => Some(p),
            };
            let _one_at_a_time = self.decide.lock().unwrap();
            match policy {
                None => return Err(FenrirError::Session("cancelled".into())),
                Some(ConflictPolicy::Skip) => return Ok(Outcome::Skipped),
                Some(ConflictPolicy::Rename) => name = unique_name(&name, &busy),
                Some(_) => {}
            }
            hold(&name);
        }
        let dst = join(&it.dst_dir, &name);
        job.set(|i| i.dst = dst.clone());
        let Some(_permit) = self.acquire(job) else { return Err(FenrirError::Session("cancelled".into())) };
        job.set(|i| i.state = TransferState::Running);
        let total = match it.direction {
            Direction::Upload => crate::sftp::local_size(std::path::Path::new(&it.src)),
            Direction::Download => {
                crate::sftp::sum_sizes(&self.ssh.run(&it.host, &crate::sftp::remote_sizes_cmd(&it.src), None, Duration::from_secs(60))?)
            }
        };
        job.set(|i| i.total = total);
        let ctx = transfer_run::Ctx { ssh: &self.ssh, host: &it.host, cancel: &job.cancel };
        let mut on = |n: u64| job.add_bytes(n);
        match (it.direction, is_dir) {
            (Direction::Upload, false) => transfer_run::upload_file(&ctx, &it.src, &dst, total, &mut on)?,
            (Direction::Upload, true) => transfer_run::upload_dir(&ctx, &it.src, &it.dst_dir, &name, &mut on)?,
            (Direction::Download, false) => transfer_run::download_file(&ctx, &it.src, &dst, &mut on)?,
            (Direction::Download, true) => transfer_run::download_dir(&ctx, &it.src, &it.dst_dir, &name, &mut on)?,
        }
        Ok(Outcome::Done)
    }
}
