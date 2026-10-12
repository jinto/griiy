//! F-IN-2/F-IN-3: every input becomes `Review { base: sha, head: sha | worktree }`.
mod common;

use common::{git, repo, write};
use griiy::{
    args::Spec,
    diff::Kind,
    git::{Error, Head, Review},
};

/// main and feature diverge from `init`: feature adds feat.txt, main then adds main.txt.
/// feature is checked out.
fn diverged(name: &str) -> common::TempDir {
    let r = repo(name, &[("base.txt", "base\n")]);
    git(&r.0, &["checkout", "-qb", "feature"]);
    write(&r.0, "feat.txt", "feat\n");
    git(&r.0, &["add", "-A"]);
    git(&r.0, &["commit", "-qm", "feat"]);
    git(&r.0, &["checkout", "-q", "main"]);
    write(&r.0, "main.txt", "main\n");
    git(&r.0, &["add", "-A"]);
    git(&r.0, &["commit", "-qm", "main"]);
    git(&r.0, &["checkout", "-q", "feature"]);
    r
}

fn sha(r: &common::TempDir, rev: &str) -> String {
    git(&r.0, &["rev-parse", rev]).trim().to_string()
}

/// Changed lines as `+text` / `-text`.
fn changes(r: &Review) -> Vec<String> {
    let lines = r.files.iter().flat_map(|f| &f.hunks).flat_map(|h| &h.lines);
    lines
        .filter_map(|l| match l.kind {
            Kind::Add => Some(format!("+{}", l.text)),
            Kind::Del => Some(format!("-{}", l.text)),
            Kind::Context => None,
        })
        .collect()
}

fn paths(r: &Review) -> Vec<&str> {
    r.files.iter().map(|f| f.path.as_str()).collect()
}

fn range(base: &str, head: &str, merge_base: bool) -> Spec {
    Spec::Range { base: base.into(), head: head.into(), merge_base }
}

#[test]
fn two_dots_compares_endpoints() {
    let r = diverged("dots2");
    let review = Review::open(&r.0, &range("main", "feature", false)).unwrap();
    assert_eq!(review.base, sha(&r, "main"));
    assert_eq!(review.head, Head::Sha(sha(&r, "feature")));
    assert_eq!(paths(&review), ["feat.txt", "main.txt"]); // main.txt shows as deleted
    assert!(changes(&review).contains(&"-main".into()), "{:?}", changes(&review));
}

#[test]
fn three_dots_compares_against_the_merge_base() {
    let r = diverged("dots3");
    let review = Review::open(&r.0, &range("main", "feature", true)).unwrap();
    assert_eq!(review.base, git(&r.0, &["merge-base", "main", "feature"]).trim());
    assert_eq!(review.head, Head::Sha(sha(&r, "feature")));
    assert_eq!(paths(&review), ["feat.txt"]);
    let one = review.file_diff(0).unwrap();
    assert_eq!((one.path.as_str(), one.hunks[0].lines[0].text.as_str()), ("feat.txt", "feat"));
}

#[test]
fn no_common_ancestor_is_a_bad_range() {
    let r = repo("orphan", &[("a.txt", "a\n")]);
    git(&r.0, &["checkout", "-q", "--orphan", "other"]);
    git(&r.0, &["commit", "-qm", "other"]);
    let e = Review::open(&r.0, &range("main", "other", true)).err().unwrap();
    assert!(matches!(&e, Error::BadRange { spec, .. } if spec == "main...other"), "{e:?}");
}

#[test]
fn worktree_includes_staged_and_unstaged_but_not_untracked() {
    let r = repo("wt", &[("staged.txt", "a\n"), ("unstaged.txt", "a\n")]);
    write(&r.0, "staged.txt", "a\nstaged\n");
    git(&r.0, &["add", "staged.txt"]);
    write(&r.0, "unstaged.txt", "a\nunstaged\n");
    write(&r.0, "untracked.txt", "new\n");
    let review = Review::open(&r.0, &Spec::default()).unwrap();
    assert_eq!(review.base, sha(&r, "HEAD"));
    assert_eq!(review.head, Head::WorkTree);
    assert_eq!(paths(&review), ["staged.txt", "unstaged.txt"]);
    assert_eq!(changes(&review), ["+staged", "+unstaged"]);
}

#[test]
fn single_rev_compares_it_with_the_worktree() {
    let r = diverged("single");
    write(&r.0, "feat.txt", "feat\nedited\n");
    let review = Review::open(&r.0, &Spec::WorkTree { base: "main".into() }).unwrap();
    assert_eq!((review.base.as_str(), &review.head), (sha(&r, "main").as_str(), &Head::WorkTree));
    assert_eq!(paths(&review), ["feat.txt", "main.txt"]);
    assert!(changes(&review).contains(&"+edited".into()), "{:?}", changes(&review));
}

#[test]
fn a_clean_tree_has_no_changes() {
    let r = repo("clean", &[("a.txt", "a\n")]);
    let review = Review::open(&r.0, &Spec::default()).unwrap();
    assert!(review.files.is_empty());
}

#[test]
fn subdirectory_opens_the_whole_repo() {
    let r = repo("subdir", &[("d/a.txt", "a\n")]);
    write(&r.0, "d/a.txt", "b\n");
    let review = Review::open(&r.0.join("d"), &Spec::default()).unwrap();
    assert_eq!((review.repo.as_path(), paths(&review)), (r.0.as_path(), vec!["d/a.txt"]));
}

#[test]
fn json_names_base_head_and_label() {
    let r = diverged("json");
    let v = Review::open(&r.0, &range("main", "feature", true)).unwrap().to_json();
    assert_eq!(v["head"], sha(&r, "feature"));
    assert_eq!(v["label"], "main...feature");
    assert!(v["base"].as_str().unwrap().len() == 40 && v.get("source").is_none(), "{v}");
    let v = Review::open(&r.0, &Spec::default()).unwrap().to_json();
    assert_eq!((v["head"].as_str(), v["label"].as_str()), (Some("worktree"), Some("HEAD vs working tree")));
}

#[test]
fn first_paint_gets_a_summary_not_the_diff() {
    let r = diverged("summary");
    let review = Review::open(&r.0, &range("main", "feature", false)).unwrap();
    let v = review.to_json();
    assert!(v.get("text").is_none() && v.get("tracked").is_none(), "{v}");
    // [path, status, added, deleted, rows, oldPath]
    assert_eq!(v["files"][0], serde_json::json!(["feat.txt", "added", 1, 0, 3, null]));
    // The first screen's rows ride along, so first paint needs no round trip.
    assert_eq!(v["first"][0], serde_json::json!(review.files[0].rows(0, usize::MAX)));
    assert_eq!((v["files"][1][0].as_str(), v["files"][1][1].as_str()), (Some("main.txt"), Some("deleted")));
}

#[test]
fn first_paint_data_stays_small_for_a_120k_line_diff() {
    let line = |f: usize, i: usize, tag: &str| format!("    let v_{f}_{i} = compute({i}, \"{tag}\");\n");
    let base: Vec<(String, String)> = (0..300)
        .map(|f| (format!("src/m{}/file{f:03}.rs", f % 10), (1..=400).map(|i| line(f, i, "a")).collect()))
        .collect();
    let r = repo("big", &base.iter().map(|(p, t)| (p.as_str(), t.as_str())).collect::<Vec<_>>());
    for (f, (path, _)) in base.iter().enumerate() {
        write(&r.0, path, &(1..=400).map(|i| line(f, i, if i % 5 == 0 { "b" } else { "a" })).collect::<String>());
    }
    let review = Review::open(&r.0, &Spec::default()).unwrap();
    let rows: usize = review.files.iter().map(|f| f.row_count()).sum();
    let size = review.to_json().to_string().len();
    assert!(rows > 120_000 && size < 100_000, "rows {rows}, init {size} bytes");
}

#[test]
fn first_paint_data_stays_small_for_one_huge_file() {
    let r = repo("huge", &[("big.txt", &(0..60_000).map(|i| format!("{i}\n")).collect::<String>())]);
    write(&r.0, "big.txt", &(0..60_000).map(|i| format!("{}\n", i * 2)).collect::<String>());
    let review = Review::open(&r.0, &Spec::default()).unwrap();
    let v = review.to_json();
    // Only the first screen of the file rides along; the rest comes from api/diff.
    let first = v["first"][0].as_array().unwrap();
    assert_eq!(first[..], review.files[0].rows(0, usize::MAX)[..first.len()]);
    assert!(first.len() < review.files[0].row_count() && v.to_string().len() < 100_000);
}

#[test]
fn unknown_revisions_are_bad_ranges_even_on_an_unborn_branch() {
    let r = repo("typo", &[("a.txt", "a\n")]);
    let e = Review::open(&r.0, &Spec::WorkTree { base: "nope".into() }).err().unwrap();
    assert!(matches!(&e, Error::BadRange { spec, .. } if spec == "nope"), "{e:?}");
    // HEAD points nowhere, but the repo has commits: still a typo, not "no commits yet".
    git(&r.0, &["checkout", "-q", "--orphan", "fresh"]);
    let e = Review::open(&r.0, &range("main", "typo", false)).err().unwrap();
    assert!(matches!(&e, Error::BadRange { spec, .. } if spec == "typo"), "{e:?}");
}

#[test]
fn renamed_file_diff_stays_a_rename() {
    let r = repo("renamefd", &[("old.txt", "1\n2\n3\n4\n5\n")]);
    git(&r.0, &["mv", "old.txt", "new.txt"]);
    write(&r.0, "new.txt", "1\n2\n3\n4\nfive\n");
    let review = Review::open(&r.0, &Spec::default()).unwrap();
    let f = review.file_diff(0).unwrap();
    assert_eq!((f.path.as_str(), f.old_path.as_deref(), f.stats()), ("new.txt", Some("old.txt"), (1, 1)));
}

#[test]
fn first_paint_data_stays_small_for_one_huge_line() {
    let r = repo("longline", &[("min.js", "a\n")]);
    write(&r.0, "min.js", &format!("{}\n", "x".repeat(1 << 20)));
    let v = Review::open(&r.0, &Spec::default()).unwrap().to_json();
    assert!(v.to_string().len() < 100_000, "{} bytes", v.to_string().len());
}
