//! Command line: `griiy [<range>] [-C <repo>]` (F-IN-1), ranges meaning what they mean to git (F-IN-2).

use std::{ffi::OsString, path::PathBuf};

const USAGE: &str = "usage: griiy [<rev> | <a>..<b> | <a>...<b>] [-C <repo>]";

#[derive(Debug, Clone, PartialEq)]
pub enum Spec {
    /// `griiy` or `griiy <rev>`: `base` (default HEAD) vs the working tree, index included.
    WorkTree { base: String },
    /// `a..b` compares the endpoints; `a...b` (`merge_base`) compares b with merge-base(a, b).
    /// An empty side is HEAD.
    Range { base: String, head: String, merge_base: bool },
}

impl Default for Spec {
    fn default() -> Spec {
        Spec::WorkTree { base: "HEAD".into() }
    }
}

impl Spec {
    /// What the user asked for, for the window header and error messages.
    pub fn label(&self) -> String {
        match self {
            Spec::WorkTree { base } => format!("{base} vs working tree"),
            Spec::Range { base, head, merge_base } => format!("{base}{}{head}", if *merge_base { "..." } else { ".." }),
        }
    }
}

#[derive(Debug)]
pub struct Args {
    pub repo: PathBuf,
    pub spec: Spec,
}

/// Parses the arguments after the program name. `Err` is a usage message for the terminal.
/// The repository path stays raw bytes; a revision must be UTF-8 (git ref names in practice are).
pub fn parse(args: impl IntoIterator<Item = OsString>) -> Result<Args, String> {
    let usage = |arg: &OsString| format!("griiy: unexpected argument '{}'\n{USAGE}", arg.to_string_lossy());
    let (mut repo, mut rev) = (None, None);
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        if arg == "-C" && repo.is_none() {
            repo = Some(args.next().ok_or_else(|| format!("griiy: -C needs a path\n{USAGE}"))?);
        } else if rev.is_some() {
            return Err(usage(&arg));
        } else {
            // Checked before range splitting, so `--output=x..HEAD` never reaches git.
            match arg.to_str() {
                Some(r) if !r.starts_with('-') => rev = Some(r.to_string()),
                _ => return Err(usage(&arg)),
            }
        }
    }
    let head = |s: &str| if s.is_empty() { "HEAD".to_string() } else { s.to_string() };
    let spec = match rev {
        None => Spec::default(),
        Some(r) => match r.split_once("...").map(|p| (p, true)).or(r.split_once("..").map(|p| (p, false))) {
            Some(((a, b), merge_base)) => Spec::Range { base: head(a), head: head(b), merge_base },
            None => Spec::WorkTree { base: r },
        },
    };
    Ok(Args { repo: repo.map_or_else(|| PathBuf::from("."), PathBuf::from), spec })
}
