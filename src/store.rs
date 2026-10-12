//! Per-review JSON documents (PRD §7.4): `<root>/<key>.json` with a schema `version`.

use serde_json::{Value, json};
use std::{
    fs,
    io::{ErrorKind, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

pub const VERSION: u64 = 1;

pub enum Source<'a> {
    GitHub {
        owner: &'a str,
        repo: &'a str,
        number: u64,
    },
    /// Ref names, not shas, so the key survives new commits. `repo` is the worktree top level.
    Range {
        repo: &'a Path,
        base: &'a str,
        head: &'a str,
    },
    WorkTree {
        repo: &'a Path,
    },
}

pub fn review_key(s: &Source) -> String {
    let key = match s {
        // GitHub names are case-insensitive, and so is the macOS file system.
        Source::GitHub { owner, repo, number } => {
            format!("gh-{}-{}-{number}", enc(&owner.to_lowercase()), enc(&repo.to_lowercase()))
        }
        Source::Range { repo, base, head } => format!("local-{}-{}-{}", repo_hash(repo), enc(base), enc(head)),
        Source::WorkTree { repo } => format!("local-{}-worktree", repo_hash(repo)),
    };
    // File names max out at 255 bytes; long ref names keep a readable prefix plus a hash of the rest.
    if key.len() <= 200 { key } else { format!("{}-{:016x}", &key[..180], fnv(key.as_bytes())) }
}

/// Bytes outside `[A-Za-z0-9._]` become `%XX`, so `-` stays an unambiguous field separator
/// and `/` in ref names can't escape the directory.
fn enc(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'.' | b'_' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

// ponytail: 64-bit FNV-1a; collisions need ~4 billion repos. Stable across Rust versions, unlike DefaultHasher.
fn fnv(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf29ce484222325, |h, &b| (h ^ b as u64).wrapping_mul(0x100000001b3))
}

/// Resolves symlinks and relative paths first, so one repo always hashes the same.
fn repo_hash(repo: &Path) -> String {
    let repo = fs::canonicalize(repo).unwrap_or_else(|_| repo.to_path_buf());
    format!("{:016x}", fnv(repo.as_os_str().as_encoded_bytes()))
}

pub struct Store {
    root: PathBuf,
}

impl Store {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Store { root: root.into() }
    }

    fn path(&self, key: &str) -> PathBuf {
        self.root.join(format!("{key}.json"))
    }

    /// A missing file is a fresh document. A corrupt or unknown-version file is moved aside
    /// to `<key>.json.corrupt-<id>` (never deleted) and a fresh document is returned.
    pub fn load(&self, key: &str) -> std::io::Result<Value> {
        let path = self.path(key);
        let bytes = match fs::read(&path) {
            Ok(b) => b,
            Err(e) if e.kind() == ErrorKind::NotFound => return Ok(fresh()),
            Err(e) => return Err(e),
        };
        match serde_json::from_slice::<Value>(&bytes) {
            Ok(v) if v.get("version").and_then(Value::as_u64).is_some_and(|n| (1..=VERSION).contains(&n)) => Ok(v),
            _ => {
                fs::rename(&path, self.root.join(format!("{key}.json.corrupt-{}", unique())))?;
                Ok(fresh())
            }
        }
    }

    /// Write to a temp file, fsync, then rename over the old file, so a crash leaves either version whole.
    // ponytail: no cross-process lock; two windows on one review is last-write-wins.
    pub fn save(&self, key: &str, doc: &Value) -> std::io::Result<()> {
        fs::create_dir_all(&self.root)?;
        let tmp = self.root.join(format!("{key}.json.tmp-{}", unique()));
        // Stamp the version so a document saved without one isn't treated as corrupt on load.
        let mut doc = doc.clone();
        if let Some(o) = doc.as_object_mut() {
            o.entry("version").or_insert(VERSION.into());
        }
        let write = || -> std::io::Result<()> {
            let mut f = fs::File::create_new(&tmp)?;
            f.write_all(&serde_json::to_vec_pretty(&doc)?)?;
            f.sync_all()?;
            fs::rename(&tmp, self.path(key))
        };
        write().inspect_err(|_| {
            let _ = fs::remove_file(&tmp);
        })?;
        // The data is already in place; a failed directory fsync only weakens crash durability.
        let _ = fs::File::open(&self.root).and_then(|d| d.sync_all());
        Ok(())
    }
}

fn fresh() -> Value {
    json!({ "version": VERSION })
}

/// Unique within and across processes: time, pid, and a counter.
fn unique() -> String {
    static N: AtomicU64 = AtomicU64::new(0);
    let t = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_nanos());
    format!("{t}-{}-{}", std::process::id(), N.fetch_add(1, Ordering::Relaxed))
}
