//! F-IN-2/F-IN-3: every input becomes `Review { base: sha, head: sha | worktree }`.
mod common;

use common::{git, repo, write};
use griiy::{
    args::Spec,
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
    assert!(review.text.contains("-main"), "{}", review.text);
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
    assert!(review.text.contains("+staged") && review.text.contains("+unstaged"), "{}", review.text);
}

#[test]
fn single_rev_compares_it_with_the_worktree() {
    let r = diverged("single");
    write(&r.0, "feat.txt", "feat\nedited\n");
    let review = Review::open(&r.0, &Spec::WorkTree { base: "main".into() }).unwrap();
    assert_eq!((review.base.as_str(), &review.head), (sha(&r, "main").as_str(), &Head::WorkTree));
    assert_eq!(paths(&review), ["feat.txt", "main.txt"]);
    assert!(review.text.contains("+edited"), "{}", review.text);
}

#[test]
fn a_clean_tree_has_no_changes() {
    let r = repo("clean", &[("a.txt", "a\n")]);
    let review = Review::open(&r.0, &Spec::default()).unwrap();
    assert!(review.files.is_empty() && review.text.is_empty());
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
