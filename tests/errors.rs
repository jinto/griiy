//! F-IN-5: each failure becomes an `Error` with a title and a fix, never a panic.
mod common;

use common::{TempDir, repo};
use griiy::{
    args::Spec,
    git::{Error, Review, fetch, resolve, run},
};
use std::os::unix::fs::PermissionsExt;

fn assert_explained(e: &Error) {
    let v = e.to_json();
    assert!(!v["title"].as_str().unwrap().is_empty() && !v["hint"].as_str().unwrap().is_empty(), "{v}");
}

#[test]
fn git_missing() {
    let t = TempDir::new("nogit");
    let e = run("griiy-no-such-git", &t.0, &["status"], None).unwrap_err();
    assert_eq!(e, Error::GitMissing);
    assert_explained(&e);
}

#[test]
fn not_a_repository() {
    let t = TempDir::new("norepo");
    let e = Review::open(&t.0, &Spec::default()).err().unwrap();
    assert!(matches!(e, Error::NotARepo { .. }), "{e:?}");
    assert_explained(&e);
    let e = Review::open(&t.0.join("does-not-exist"), &Spec::default()).err().unwrap();
    assert!(matches!(e, Error::NotARepo { .. }), "{e:?}");
}

#[test]
fn bad_range() {
    let r = repo("range", &[("a.txt", "a\n")]);
    assert_eq!(resolve(&r.0, "main").unwrap().len(), 40);
    for spec in ["no-such-branch", "main~5", "--output=/tmp/x"] {
        let e = resolve(&r.0, spec).unwrap_err();
        assert!(matches!(&e, Error::BadRange { spec: s, .. } if s == spec), "{e:?}");
        assert_explained(&e);
    }
}

#[test]
fn fetch_failed() {
    let r = repo("fetch", &[("a.txt", "a\n")]);
    let e = fetch(&r.0, "/nonexistent/griiy-remote", "main").unwrap_err();
    assert!(matches!(e, Error::FetchFailed { .. }), "{e:?}");
    assert_explained(&e);
}

#[test]
fn permission_denied() {
    let t = TempDir::new("perm");
    let locked = t.0.join("locked");
    std::fs::create_dir(&locked).unwrap();
    std::fs::set_permissions(&locked, PermissionsExt::from_mode(0o000)).unwrap();
    let readable = std::fs::read_dir(&locked).is_ok(); // true when running as root
    let result = Review::open(&locked, &Spec::default()).err();
    std::fs::set_permissions(&locked, PermissionsExt::from_mode(0o755)).unwrap(); // so TempDir can clean up
    if readable {
        eprintln!("skipped: running as root");
        return;
    }
    let e = result.unwrap();
    assert!(matches!(e, Error::PermissionDenied { .. }), "{e:?}");
    assert_explained(&e);
}

#[test]
fn no_commits_yet() {
    let t = TempDir::new("empty");
    common::git(&t.0, &["init", "-q"]);
    let e = Review::open(&t.0, &Spec::default()).err().unwrap();
    assert!(matches!(e, Error::NoCommits { .. }), "{e:?}");
    assert_explained(&e);
}

#[test]
fn every_error_explains_itself() {
    let s = String::new;
    for e in [
        Error::GitMissing,
        Error::NotARepo { path: s() },
        Error::NoCommits { path: s() },
        Error::BadRange { spec: s(), detail: s() },
        Error::FetchFailed { remote: s(), detail: s() },
        Error::PermissionDenied { path: s(), detail: s() },
        Error::Git { detail: s() },
        Error::Cancelled,
    ] {
        assert_explained(&e);
    }
}
