//! git CLI wrapper and the errors shown on the in-window error screen (F-IN-5).

use crate::args::Spec;
use serde_json::{Value, json};
use std::{
    io::{ErrorKind, Read},
    os::unix::process::CommandExt,
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::{Duration, Instant},
};

#[derive(Debug, Clone, PartialEq)]
pub enum Error {
    GitMissing,
    NotARepo { path: String },
    NoCommits { path: String },
    BadRange { spec: String, detail: String },
    FetchFailed { remote: String, detail: String },
    PermissionDenied { path: String, detail: String },
    Git { detail: String },
    Cancelled,
}

impl Error {
    pub fn title(&self) -> String {
        match self {
            Error::GitMissing => "git is not installed".into(),
            Error::NotARepo { path } => format!("{path} is not a git repository"),
            Error::NoCommits { path } => format!("{path} has no commits yet"),
            Error::BadRange { spec, .. } => format!("Unknown revision or range: {spec}"),
            Error::FetchFailed { remote, .. } => format!("Could not fetch from {remote}"),
            Error::PermissionDenied { path, .. } => format!("Permission denied: {path}"),
            Error::Git { .. } => "git failed".into(),
            Error::Cancelled => "Cancelled".into(),
        }
    }

    pub fn hint(&self) -> &'static str {
        match self {
            Error::GitMissing => {
                "Install git (xcode-select --install or brew install git) and make sure it is on PATH."
            }
            Error::NotARepo { .. } => "Run griiy inside a git repository, or pass its path: griiy -C path/to/repo.",
            Error::NoCommits { .. } => "Make a first commit, then run griiy again.",
            Error::BadRange { .. } => {
                "Check the branch or commit names. Ranges look like main..feature or main...feature. To open another repository: griiy -C path/to/repo."
            }
            Error::FetchFailed { .. } => "Check your network and that the remote exists, then run griiy again.",
            Error::PermissionDenied { .. } => {
                "Check file permissions, or for a private repository, that you are logged in (gh auth status)."
            }
            Error::Git { .. } => "git reported the error above. Fix it and run griiy again.",
            Error::Cancelled => "The request was cancelled.",
        }
    }

    fn detail(&self) -> &str {
        match self {
            Error::BadRange { detail, .. }
            | Error::FetchFailed { detail, .. }
            | Error::PermissionDenied { detail, .. }
            | Error::Git { detail } => detail,
            _ => "",
        }
    }

    pub fn to_json(&self) -> Value {
        json!({ "title": self.title(), "detail": self.detail(), "hint": self.hint() })
    }
}

/// Runs `<program> -C <repo> <args>` and returns stdout. `cancel` kills the child, and anything
/// it started (ssh, remote helpers), when set. Messages are forced to English (LC_ALL=C) so
/// failures can be classified from stderr.
pub fn run(program: &str, repo: &Path, args: &[&str], cancel: Option<&AtomicBool>) -> Result<Vec<u8>, Error> {
    let mut cmd = Command::new(program);
    cmd.arg("-C")
        .arg(repo)
        .args(args)
        .env("LC_ALL", "C")
        .env("GIT_TERMINAL_PROMPT", "0")
        // Paths come from git itself; never let them act as pathspec magic like `:(glob)`.
        .env("GIT_LITERAL_PATHSPECS", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // Its own process group, so cancelling can kill the whole tree.
        .process_group(0);
    let spawn_err = |e: std::io::Error| match e.kind() {
        ErrorKind::NotFound => Error::GitMissing,
        _ => Error::Git { detail: e.to_string() },
    };
    let output = match cancel {
        None => cmd.output().map_err(spawn_err)?,
        Some(cancel) => {
            let mut child = cmd.spawn().map_err(spawn_err)?;
            // Drain both pipes on threads so a chatty child can't block on a full pipe.
            let drain = |r: Option<Box<dyn Read + Send>>| {
                thread::spawn(move || {
                    let mut buf = Vec::new();
                    if let Some(mut r) = r {
                        let _ = r.read_to_end(&mut buf);
                    }
                    buf
                })
            };
            let out = drain(child.stdout.take().map(|r| Box::new(r) as _));
            let err = drain(child.stderr.take().map(|r| Box::new(r) as _));
            // ponytail: polls every 2ms; a pidfd/kqueue wait is the upgrade if that ever shows up in a profile.
            let status = loop {
                let stop = match child.try_wait() {
                    Ok(Some(s)) => break Ok(s),
                    Ok(None) if !cancel.load(Ordering::Relaxed) => {
                        thread::sleep(Duration::from_millis(2));
                        continue;
                    }
                    Ok(None) => Error::Cancelled,
                    Err(e) => Error::Git { detail: e.to_string() },
                };
                let _ = Command::new("/bin/kill").arg("-KILL").arg(format!("-{}", child.id())).status();
                let _ = child.wait();
                break Err(stop);
            };
            // Every holder of the pipes is gone now, so these joins return.
            let (stdout, stderr) = (out.join().unwrap_or_default(), err.join().unwrap_or_default());
            Output { status: status?, stdout, stderr }
        }
    };
    if output.status.success() {
        return Ok(output.stdout);
    }
    let err = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let path = repo.display().to_string();
    Err(if err.contains("Permission denied") {
        Error::PermissionDenied { path, detail: err }
    } else if err.contains("not a git repository") || err.contains("cannot change to") {
        Error::NotARepo { path }
    } else if err.contains("xcode-select") {
        // /usr/bin/git is a shim that fails this way until the Command Line Tools are installed.
        Error::GitMissing
    } else {
        Error::Git { detail: err }
    })
}

fn git(repo: &Path, args: &[&str]) -> Result<String, Error> {
    run("git", repo, args, None).map(|b| String::from_utf8_lossy(&b).into_owned())
}

/// Commit sha for a revision. The only place user-typed revisions reach git.
pub fn resolve(repo: &Path, rev: &str) -> Result<String, Error> {
    let spec = format!("{rev}^{{commit}}");
    match git(repo, &["rev-parse", "--verify", "--end-of-options", &spec]) {
        Ok(sha) => Ok(sha.trim().into()),
        Err(Error::Git { detail }) => Err(Error::BadRange { spec: rev.into(), detail }),
        Err(e) => Err(e),
    }
}

/// `git fetch <remote> <refspec>` (M2-2 builds PR fetches on this).
pub fn fetch(repo: &Path, remote: &str, refspec: &str) -> Result<(), Error> {
    match git(repo, &["fetch", "--no-tags", "--quiet", "--end-of-options", remote, refspec]) {
        Ok(_) => Ok(()),
        Err(Error::Git { detail }) => Err(Error::FetchFailed { remote: remote.into(), detail }),
        Err(e) => Err(e),
    }
}

/// The other side of a review: a commit, or the working tree (index included).
#[derive(Debug, PartialEq)]
pub enum Head {
    Sha(String),
    WorkTree,
}

/// What the window shows (F-IN-3). Every diff is computed from the resolved shas, so
/// user-typed revisions never reach git outside `resolve`.
pub struct Review {
    pub repo: PathBuf,
    /// Kept for the store key (M1-13), which wants the ref names, not the shas.
    pub spec: Spec,
    pub base: String,
    pub head: Head,
    pub text: String,
    /// Changed paths; a path's index here is its file ID for `griiy://api/diff?id=`.
    pub files: Vec<String>,
    pub tracked: String,
    pub git_ms: u64,
}

impl Review {
    pub fn open(dir: &Path, spec: &Spec) -> Result<Review, Error> {
        let start = Instant::now();
        let repo = PathBuf::from(git(dir, &["rev-parse", "--show-toplevel"])?.trim_end_matches('\n'));
        let sha = |rev: &str| {
            resolve(&repo, rev).map_err(|e| match e {
                // Only on failure: an unborn HEAD in a repo with commits (orphan branch) is still a typo.
                Error::BadRange { .. } if git(&repo, &["rev-list", "-n1", "--all"]).is_ok_and(|s| s.is_empty()) => {
                    Error::NoCommits { path: repo.display().to_string() }
                }
                e => e,
            })
        };
        let (base, head) = match spec {
            Spec::WorkTree { base } => (sha(base)?, Head::WorkTree),
            Spec::Range { base, head, merge_base } => {
                let (a, b) = (sha(base)?, sha(head)?);
                let base = if *merge_base {
                    // git prints one base when there are several: the one `git diff a...b` uses.
                    // With both sides resolved, failing means no common ancestor (exit 1, empty stderr).
                    git(&repo, &["merge-base", &a, &b]).map(|s| s.trim().to_string()).map_err(|e| match e {
                        Error::Git { .. } => {
                            Error::BadRange { spec: spec.label(), detail: "no common ancestor".into() }
                        }
                        e => e,
                    })?
                } else {
                    a
                };
                (base, Head::Sha(b))
            }
        };
        let text = diff(&repo, &base, &head, &[])?;
        let names = diff(&repo, &base, &head, &["--name-only", "-z"])?;
        let files = names.split('\0').filter(|s| !s.is_empty()).map(String::from).collect();
        let tracked = git(&repo, &["ls-files"])?;
        let git_ms = start.elapsed().as_millis() as u64;
        Ok(Review { repo, spec: spec.clone(), base, head, text, files, tracked, git_ms })
    }

    /// Diff of one changed file, addressed only by its ID. `None` for an unknown ID.
    pub fn file_diff(&self, id: usize) -> Option<Result<String, Error>> {
        let path = self.files.get(id)?;
        Some(diff(&self.repo, &self.base, &self.head, &["--", path.as_str()]))
    }

    pub fn to_json(&self) -> Value {
        let head = match &self.head {
            Head::Sha(h) => h.as_str(),
            Head::WorkTree => "worktree",
        };
        json!({ "repo": self.repo, "label": self.spec.label(), "base": self.base, "head": head,
                "text": self.text, "tracked": self.tracked, "gitMs": self.git_ms })
    }
}

/// `git diff <base> [<head>] <extra>`, from resolved shas only.
fn diff(repo: &Path, base: &str, head: &Head, extra: &[&str]) -> Result<String, Error> {
    let mut args = vec!["diff", "--no-color", "--no-ext-diff", base];
    if let Head::Sha(h) = head {
        args.push(h);
    }
    args.extend(extra);
    git(repo, &args)
}
