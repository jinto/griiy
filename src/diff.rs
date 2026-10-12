//! Unified diff text → files, hunks and lines (F-DV-10). Pure: no git calls, never panics.
//!
//! Expects the output of `git::diff` (fixed prefixes `a/` `b/`, `--full-index`); names may be C-quoted or raw.
//! Names come from the most reliable line present: `rename/copy from|to`, then `---`/`+++`,
//! then `diff --git` (the only source for binary, mode-only and empty files). Hunks end by their
//! header's line counts, so content can never be mistaken for a header.

use serde_json::{Value, json};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Status {
    Added,
    Deleted,
    Modified,
    Renamed,
    Copied,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Kind {
    Context,
    Add,
    Del,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Line {
    pub kind: Kind,
    /// Line numbers in the base and head files; `None` on the side the line isn't on.
    pub old_no: Option<u32>,
    pub new_no: Option<u32>,
    /// Without the +/-/space prefix. A CRLF file keeps its `\r`.
    pub text: String,
    /// `\ No newline at end of file` followed this line.
    pub no_newline: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Hunk {
    pub old_start: u32,
    pub old_len: u32,
    pub new_start: u32,
    pub new_len: u32,
    /// Text after the second `@@` (git's function-name guess), trimmed.
    pub section: String,
    pub lines: Vec<Line>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct File {
    /// Head-side path; the base-side path for a deletion. Display only: names that aren't
    /// UTF-8 are decoded lossily, so a file's identity is its ID and blob ids, never this.
    pub path: String,
    /// Base-side path of a rename or copy.
    pub old_path: Option<String>,
    pub status: Status,
    pub old_mode: Option<String>,
    pub new_mode: Option<String>,
    pub old_blob: Option<String>,
    pub new_blob: Option<String>,
    pub binary: bool,
    pub hunks: Vec<Hunk>,
}

impl File {
    /// (added, deleted) lines.
    pub fn stats(&self) -> (u32, u32) {
        let lines = self.hunks.iter().flat_map(|h| &h.lines);
        lines.fold((0, 0), |(a, d), l| match l.kind {
            Kind::Add => (a + 1, d),
            Kind::Del => (a, d + 1),
            Kind::Context => (a, d),
        })
    }

    /// Rows on screen: the file header, then each hunk's header and lines, or one note row when
    /// there are no hunks. The frontend sizes the whole scroll area from this before any rows load.
    pub fn row_count(&self) -> usize {
        1 + match self.hunks.len() {
            0 => 1,
            n => n + self.hunks.iter().map(|h| h.lines.len()).sum::<usize>(),
        }
    }

    /// The rows themselves, compact for `api/diff`: `["f"]` file header (drawn from the summary),
    /// `["h", "@@ … @@ section"]`, `[" "|"+"|"-", old, new, text]` plus a trailing `1` when
    /// `\ No newline at end of file` follows, `["n", note]`. Of the `row_count()` rows, the
    /// window `from..from + n`.
    pub fn rows(&self, from: usize, n: usize) -> Vec<Value> {
        let end = from.saturating_add(n);
        let want = |i: usize| (from..end).contains(&i);
        let mut rows = Vec::new();
        if want(0) {
            rows.push(json!(["f"]));
        }
        if self.hunks.is_empty() {
            if want(1) {
                rows.push(json!(["n", self.note()]));
            }
            return rows;
        }
        // Whole hunks before the window are skipped by their size, so a window deep in a huge
        // file costs its own rows, not everything above it.
        let mut at = 1;
        for h in &self.hunks {
            if at >= end {
                break;
            }
            if at + 1 + h.lines.len() > from {
                if want(at) {
                    let head =
                        format!("@@ -{},{} +{},{} @@ {}", h.old_start, h.old_len, h.new_start, h.new_len, h.section);
                    rows.push(json!(["h", head.trim_end()]));
                }
                let last = (end - (at + 1)).min(h.lines.len());
                let first = from.saturating_sub(at + 1).min(last);
                rows.extend(h.lines[first..last].iter().map(|l| {
                    let kind = match l.kind {
                        Kind::Context => " ",
                        Kind::Add => "+",
                        Kind::Del => "-",
                    };
                    match l.no_newline {
                        true => json!([kind, l.old_no, l.new_no, l.text, 1]),
                        false => json!([kind, l.old_no, l.new_no, l.text]),
                    }
                }));
            }
            at += 1 + h.lines.len();
        }
        rows
    }

    /// Why a file with no hunks is in the diff.
    fn note(&self) -> String {
        match (&self.old_mode, &self.new_mode) {
            _ if self.binary => "Binary file".into(),
            (Some(a), Some(b)) if a != b => format!("Mode {a} → {b}"),
            _ => "No content changes".into(),
        }
    }

    /// First-paint summary: `[path, status, added, deleted, rows, oldPath]`. A tuple, not
    /// an object, so a 120k-line review fits in well under 100KB (M1-5).
    pub fn summary(&self) -> Value {
        let (add, del) = self.stats();
        let status = format!("{:?}", self.status).to_lowercase();
        json!([self.path, status, add, del, self.row_count(), self.old_path])
    }
}

/// A file while its header is read: names from each source, kept apart until the end.
#[derive(Default)]
struct Draft {
    git_names: Option<(String, String)>,
    /// `---`/`+++`; `/dev/null` reads as absent, and the mode lines say added or deleted.
    minus: Option<String>,
    plus: Option<String>,
    from: Option<String>,
    to: Option<String>,
    status: Option<Status>,
    old_mode: Option<String>,
    new_mode: Option<String>,
    old_blob: Option<String>,
    new_blob: Option<String>,
    binary: bool,
    hunks: Vec<Hunk>,
}

impl Draft {
    /// `None` only when no line named the file, which git's own output never does.
    fn finish(self) -> Option<File> {
        let (git_old, git_new) = self.git_names.unzip();
        let old = self.from.or(self.minus).or(git_old);
        let new = self.to.or(self.plus).or(git_new);
        let status = self.status.unwrap_or(Status::Modified);
        let (path, old_path) = match status {
            Status::Deleted => (old?, None),
            Status::Renamed | Status::Copied => (new?, old),
            Status::Added | Status::Modified => (new.or(old)?, None),
        };
        let (mut old_mode, mut new_mode) = (self.old_mode, self.new_mode);
        // `index a..b <mode>` gives the mode when it didn't change; a side that doesn't exist has none.
        if status != Status::Added && old_mode.is_none() {
            old_mode = new_mode.clone();
        }
        if status == Status::Deleted {
            new_mode = None;
        }
        Some(File {
            path,
            old_path,
            status,
            old_mode,
            new_mode,
            old_blob: self.old_blob,
            new_blob: self.new_blob,
            binary: self.binary,
            hunks: self.hunks,
        })
    }
}

pub fn parse(text: &str) -> Vec<File> {
    let mut files = Vec::new();
    let mut draft: Option<Draft> = None;
    // Without the final newline, so a hunk cut short can't pick up a phantom empty line.
    let mut lines = text.strip_suffix('\n').unwrap_or(text).split('\n').peekable();
    while let Some(line) = lines.next() {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            files.extend(draft.take().and_then(Draft::finish));
            draft = Some(Draft { git_names: git_names(rest), ..Draft::default() });
            continue;
        }
        let Some(d) = draft.as_mut() else { continue };
        if line.starts_with("@@ ") {
            let Some(mut hunk) = hunk_header(line) else {
                // A header we can't read: keep the hunks so far and skip to the next file.
                files.extend(draft.take().and_then(Draft::finish));
                continue;
            };
            let (mut old_no, mut new_no) = (hunk.old_start, hunk.new_start);
            let (mut old_left, mut new_left) = (hunk.old_len, hunk.new_len);
            // The `\` marker for the hunk's last line comes after the counts run out.
            while old_left > 0 || new_left > 0 || lines.peek().is_some_and(|l| l.starts_with('\\')) {
                // Peek, so a hunk cut short leaves the next file's header in place.
                let Some(&l) = lines.peek() else { break };
                // `diff.suppressBlankEmpty` prints an empty context line with no space.
                let (kind, body) = match l.as_bytes().first() {
                    Some(b'+') => (Kind::Add, &l[1..]),
                    Some(b'-') => (Kind::Del, &l[1..]),
                    Some(b' ') => (Kind::Context, &l[1..]),
                    None => (Kind::Context, ""),
                    Some(b'\\') => {
                        lines.next();
                        if let Some(l) = hunk.lines.last_mut() {
                            l.no_newline = true;
                        }
                        continue;
                    }
                    Some(_) => break,
                };
                lines.next();
                let (o, n) = match kind {
                    Kind::Add => (None, Some(new_no)),
                    Kind::Del => (Some(old_no), None),
                    Kind::Context => (Some(old_no), Some(new_no)),
                };
                if o.is_some() {
                    old_no += 1;
                    old_left = old_left.saturating_sub(1);
                }
                if n.is_some() {
                    new_no += 1;
                    new_left = new_left.saturating_sub(1);
                }
                hunk.lines.push(Line { kind, old_no: o, new_no: n, text: body.into(), no_newline: false });
            }
            d.hunks.push(hunk);
        } else if let Some(p) = line.strip_prefix("--- ") {
            d.minus = header_path(p, "a/");
        } else if let Some(p) = line.strip_prefix("+++ ") {
            d.plus = header_path(p, "b/");
        } else if let Some(p) = line.strip_prefix("rename from ").or(line.strip_prefix("copy from ")) {
            d.from = Some(name(p));
        } else if let Some(p) = line.strip_prefix("rename to ") {
            (d.to, d.status) = (Some(name(p)), Some(Status::Renamed));
        } else if let Some(p) = line.strip_prefix("copy to ") {
            (d.to, d.status) = (Some(name(p)), Some(Status::Copied));
        } else if let Some(m) = line.strip_prefix("new file mode ") {
            (d.new_mode, d.status) = (Some(m.into()), Some(Status::Added));
        } else if let Some(m) = line.strip_prefix("deleted file mode ") {
            (d.old_mode, d.status) = (Some(m.into()), Some(Status::Deleted));
        } else if let Some(m) = line.strip_prefix("old mode ") {
            d.old_mode = Some(m.into());
        } else if let Some(m) = line.strip_prefix("new mode ") {
            d.new_mode = Some(m.into());
        } else if let Some(rest) = line.strip_prefix("index ") {
            let (blobs, mode) = rest.split_once(' ').unwrap_or((rest, ""));
            let blob = |s: &str| (!s.bytes().all(|b| b == b'0')).then(|| s.to_string());
            if let Some((a, b)) = blobs.split_once("..") {
                (d.old_blob, d.new_blob) = (blob(a), blob(b));
            }
            if !mode.is_empty() {
                d.new_mode.get_or_insert_with(|| mode.into());
            }
        } else if line.starts_with("Binary files ") || line == "GIT binary patch" {
            d.binary = true;
        }
        // Anything else (similarity, dissimilarity, binary payload) carries nothing we use.
    }
    files.extend(draft.and_then(Draft::finish));
    files
}

/// `@@ -a[,b] +c[,d] @@ section`. A missing count is 1. Rejects ranges that would overflow the
/// line counters.
fn hunk_header(line: &str) -> Option<Hunk> {
    let rest = line.strip_prefix("@@ -")?;
    let (ranges, section) = rest.split_once(" @@").unwrap_or((rest, ""));
    let (old, new) = ranges.split_once(" +")?;
    let range = |s: &str| -> Option<(u32, u32)> {
        match s.split_once(',') {
            Some((start, len)) => Some((start.parse().ok()?, len.parse().ok()?)),
            None => Some((s.parse().ok()?, 1)),
        }
        .filter(|(start, len): &(u32, u32)| start.checked_add(*len).is_some())
    };
    let ((old_start, old_len), (new_start, new_len)) = (range(old)?, range(new)?);
    let section = section.trim().into();
    Some(Hunk { old_start, old_len, new_start, new_len, section, lines: Vec::new() })
}

/// A `---`/`+++` operand: `/dev/null` is no file. git appends a TAB after names with spaces,
/// outside the quotes, so it goes first.
fn header_path(p: &str, prefix: &str) -> Option<String> {
    let p = p.strip_suffix('\t').unwrap_or(p);
    if p == "/dev/null" {
        return None;
    }
    let n = name(p);
    Some(n.strip_prefix(prefix).map(String::from).unwrap_or(n))
}

/// `a/P b/P` or `"a/P" "b/P"`. Without quotes the line is ambiguous when P has spaces, but both
/// names are the same unless it's a rename or copy, which carry their own `from`/`to` lines.
fn git_names(rest: &str) -> Option<(String, String)> {
    let (old, new) = if rest.starts_with('"') {
        let (old, after) = unquote(rest)?;
        let after = after.strip_prefix(' ')?;
        (old, if after.starts_with('"') { unquote(after)?.0 } else { after.to_string() })
    } else {
        // "a/" P " b/" P
        let half = rest.len().checked_sub(5)? / 2;
        let (old, new) = (rest.get(..half + 2)?, rest.get(half + 3..)?);
        (old.to_string(), new.to_string())
    };
    Some((old.strip_prefix("a/")?.to_string(), new.strip_prefix("b/")?.to_string()))
}

/// A name on a `rename from`-style line: C-quoted or raw.
fn name(p: &str) -> String {
    match unquote(p) {
        Some((s, _)) if p.starts_with('"') => s,
        _ => p.to_string(),
    }
}

/// Reads one C-quoted string from the start of `s` (git's `quote_c_style`): returns it and
/// what follows the closing quote. Octal escapes are raw bytes, decoded as UTF-8 at the end.
fn unquote(s: &str) -> Option<(String, &str)> {
    let mut bytes = Vec::new();
    let mut it = s.strip_prefix('"')?.bytes().enumerate();
    while let Some((i, b)) = it.next() {
        match b {
            b'"' => return Some((String::from_utf8_lossy(&bytes).into_owned(), &s[i + 2..])),
            b'\\' => {
                let (_, e) = it.next()?;
                bytes.push(match e {
                    b'a' => 7,
                    b'b' => 8,
                    b't' => b'\t',
                    b'n' => b'\n',
                    b'v' => 11,
                    b'f' => 12,
                    b'r' => b'\r',
                    b'0'..=b'3' => {
                        let (_, x) = it.next()?;
                        let (_, y) = it.next()?;
                        if !(b'0'..=b'7').contains(&x) || !(b'0'..=b'7').contains(&y) {
                            return None;
                        }
                        (e - b'0') * 64 + (x - b'0') * 8 + (y - b'0')
                    }
                    other => other, // \" and \\
                });
            }
            _ => bytes.push(b),
        }
    }
    None
}
