//! F-IN-1: `griiy [<range>] [-C <repo>]`, with git's range meanings (F-IN-2).
use griiy::args::{Args, Spec, parse};
use std::{ffi::OsString, os::unix::ffi::OsStringExt, path::PathBuf};

fn p(args: &[&str]) -> Result<Args, String> {
    parse(args.iter().map(OsString::from))
}

fn spec(args: &[&str]) -> Spec {
    p(args).unwrap().spec
}

fn wt(base: &str) -> Spec {
    Spec::WorkTree { base: base.into() }
}

fn range(base: &str, head: &str, merge_base: bool) -> Spec {
    Spec::Range { base: base.into(), head: head.into(), merge_base }
}

#[test]
fn ranges_follow_git() {
    assert_eq!(spec(&[]), wt("HEAD"));
    assert_eq!(spec(&[]), Spec::default());
    assert_eq!(spec(&["main"]), wt("main"));
    assert_eq!(spec(&["a..b"]), range("a", "b", false));
    assert_eq!(spec(&["a...b"]), range("a", "b", true));
    assert_eq!(spec(&["main.."]), range("main", "HEAD", false));
    assert_eq!(spec(&["..b"]), range("HEAD", "b", false));
    assert_eq!(spec(&["...b"]), range("HEAD", "b", true));
    assert_eq!(spec(&[".."]), range("HEAD", "HEAD", false));
    assert_eq!(spec(&["..."]), range("HEAD", "HEAD", true));
    // Odd shapes go to git as revisions; resolve() rejects them on the error screen.
    assert_eq!(spec(&["a....b"]), range("a", ".b", true));
    assert_eq!(spec(&["feature/x...origin/main"]), range("feature/x", "origin/main", true));
}

#[test]
fn repo_flag() {
    assert_eq!(p(&[]).unwrap().repo, PathBuf::from("."));
    for args in [&["-C", "x", "a..b"][..], &["a..b", "-C", "x"]] {
        let a = p(args).unwrap();
        assert_eq!((a.repo, a.spec), (PathBuf::from("x"), range("a", "b", false)));
    }
    assert_eq!(p(&["-C", "한글 dir"]).unwrap().repo, PathBuf::from("한글 dir"));
    // Paths are bytes on Unix: a non-UTF-8 directory must reach git unchanged.
    let raw = OsString::from_vec(b"repo-\xff".to_vec());
    assert_eq!(parse([OsString::from("-C"), raw.clone()]).unwrap().repo, PathBuf::from(raw));
}

#[test]
fn usage_errors() {
    for args in [
        &["-C"][..],
        &["-C", "x", "-C", "y"],
        &["a", "b"],
        &["--foo"],
        &["-x"],
        &["--output=/tmp/x..HEAD"],
        &["-C", "x", "--output=/tmp/x"],
    ] {
        let e = p(args).unwrap_err();
        assert!(e.starts_with("griiy: ") && e.contains("usage"), "{args:?}: {e}");
    }
    let e = parse([OsString::from_vec(b"main..\xff".to_vec())]).unwrap_err();
    assert!(e.contains("usage"), "{e}");
}
