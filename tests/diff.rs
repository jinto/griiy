//! M1-3 (F-DV-10): unified diff → files, hunks and lines, from real git output.
mod common;

use common::{git, repo, write};
use griiy::{
    args::Spec,
    diff::{File, Kind, Status, parse},
    git::Review,
};
use std::os::unix::fs::{PermissionsExt, symlink};

/// Commits `change` on top of `files` and returns the parsed `HEAD~1..HEAD` review.
fn changed(name: &str, files: &[(&str, &str)], change: impl FnOnce(&std::path::Path)) -> Vec<File> {
    let r = repo(name, files);
    change(&r.0);
    git(&r.0, &["add", "-A"]);
    git(&r.0, &["commit", "-qm", "change"]);
    let spec = Spec::Range { base: "HEAD~1".into(), head: "HEAD".into(), merge_base: false };
    Review::open(&r.0, &spec).unwrap().files
}

fn one(files: &[File], path: &str) -> File {
    let found: Vec<_> = files.iter().filter(|f| f.path == path).collect();
    assert_eq!(found.len(), 1, "{path} in {:?}", files.iter().map(|f| &f.path).collect::<Vec<_>>());
    found[0].clone()
}

/// `(kind, old_no, new_no, text)` per line of every hunk.
fn lines(f: &File) -> Vec<(Kind, Option<u32>, Option<u32>, String)> {
    f.hunks.iter().flat_map(|h| &h.lines).map(|l| (l.kind, l.old_no, l.new_no, l.text.clone())).collect()
}

const TEN: &str = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n";

#[test]
fn modified_file_has_hunks_with_line_numbers() {
    let files = changed("mod", &[("a.txt", TEN)], |d| write(d, "a.txt", "1\n2\n3\n4\n5\n6\n7\n8\nnine\n10\n"));
    let f = one(&files, "a.txt");
    assert_eq!((f.status, f.old_path.as_deref(), f.binary), (Status::Modified, None, false));
    assert_eq!((f.old_mode.as_deref(), f.new_mode.as_deref()), (Some("100644"), Some("100644")));
    assert_eq!((f.old_blob.as_ref().map(String::len), f.new_blob.as_ref().map(String::len)), (Some(40), Some(40)));
    assert_eq!(f.hunks.len(), 1);
    let h = &f.hunks[0];
    assert_eq!((h.old_start, h.old_len, h.new_start, h.new_len), (6, 5, 6, 5));
    use Kind::*;
    assert_eq!(
        lines(&f)[2..6],
        [
            (Context, Some(8), Some(8), "8".into()),
            (Del, Some(9), None, "9".into()),
            (Add, None, Some(9), "nine".into()),
            (Context, Some(10), Some(10), "10".into()),
        ]
    );
    assert_eq!(f.stats(), (1, 1));
}

#[test]
fn added_deleted_and_empty_files() {
    let files = changed("adddel", &[("gone.txt", "bye\n")], |d| {
        std::fs::remove_file(d.join("gone.txt")).unwrap();
        write(d, "new.txt", "hi\n");
        write(d, "empty.txt", "");
    });
    let f = one(&files, "new.txt");
    assert_eq!(
        (f.status, f.old_mode.as_deref(), f.new_mode.as_deref(), f.old_blob.as_deref()),
        (Status::Added, None, Some("100644"), None)
    );
    assert_eq!(lines(&f), [(Kind::Add, None, Some(1), "hi".into())]);
    let f = one(&files, "gone.txt");
    assert_eq!(
        (f.status, f.old_mode.as_deref(), f.new_mode.as_deref(), f.new_blob.as_deref()),
        (Status::Deleted, Some("100644"), None, None)
    );
    assert_eq!(lines(&f), [(Kind::Del, Some(1), None, "bye".into())]);
    // No hunk and no ---/+++: the name comes from the `diff --git` line alone.
    let f = one(&files, "empty.txt");
    assert_eq!((f.status, f.hunks.len(), f.binary), (Status::Added, 0, false));
}

#[test]
fn renames_and_copies() {
    // Distinct bodies, so each rename or copy has exactly one possible source.
    let body = |tag: &str| (1..=8).map(|i| format!("{tag}{i}\n")).collect::<String>();
    let (body, edit, src) = (&body("o"), &body("e"), &body("s"));
    let files = changed("rename", &[("old.txt", body), ("edit-old.txt", edit), ("src.txt", src)], |d| {
        std::fs::create_dir(d.join("dir")).unwrap();
        git(d, &["mv", "old.txt", "dir/new.txt"]);
        git(d, &["mv", "edit-old.txt", "edit-new.txt"]);
        write(d, "edit-new.txt", &edit.replace("e8", "E8"));
        // -C finds copies whose source changed in the same diff (plan R6).
        write(d, "copy.txt", src);
        write(d, "src.txt", &src.replace("s1", "S1"));
    });
    let f = one(&files, "dir/new.txt");
    assert_eq!((f.status, f.old_path.as_deref(), f.hunks.len()), (Status::Renamed, Some("old.txt"), 0));
    let f = one(&files, "edit-new.txt");
    assert_eq!((f.status, f.old_path.as_deref()), (Status::Renamed, Some("edit-old.txt")));
    assert_eq!(f.stats(), (1, 1));
    let f = one(&files, "copy.txt");
    assert_eq!((f.status, f.old_path.as_deref()), (Status::Copied, Some("src.txt")));
    assert_eq!(one(&files, "src.txt").status, Status::Modified);
}

#[test]
fn binary_mode_and_type_changes() {
    let files = changed("bin", &[("b.dat", "\0\x01"), ("run.sh", "echo\n"), ("link", "target\n")], |d| {
        write(d, "b.dat", "\0\x02");
        write(d, "새 그림.png", "\0png");
        std::fs::set_permissions(d.join("run.sh"), PermissionsExt::from_mode(0o755)).unwrap();
        std::fs::remove_file(d.join("link")).unwrap();
        symlink("b.dat", d.join("link")).unwrap();
    });
    let f = one(&files, "b.dat");
    assert_eq!((f.status, f.binary, f.hunks.len()), (Status::Modified, true, 0));
    // Quoted name, and the `diff --git` line is its only source.
    let f = one(&files, "새 그림.png");
    assert_eq!((f.status, f.binary), (Status::Added, true));
    let f = one(&files, "run.sh");
    assert_eq!((f.old_mode.as_deref(), f.new_mode.as_deref(), f.hunks.len()), (Some("100644"), Some("100755"), 0));
    // File → symlink is two blocks for one path: a deletion and an addition.
    let link: Vec<_> = files.iter().filter(|f| f.path == "link").map(|f| (f.status, f.new_mode.clone())).collect();
    assert_eq!(link, [(Status::Deleted, None), (Status::Added, Some("120000".into()))]);
}

#[test]
fn no_newline_and_crlf() {
    let files = changed("eol", &[("a.txt", "x"), ("b.txt", "keep\nx"), ("crlf.txt", "a\r\nb\r\n")], |d| {
        write(d, "a.txt", "y");
        write(d, "b.txt", "keep\nx\nmore\n");
        write(d, "crlf.txt", "a\r\nB\r\n");
    });
    let a = one(&files, "a.txt");
    let flags: Vec<_> = a.hunks[0].lines.iter().map(|l| (l.text.as_str(), l.no_newline)).collect();
    assert_eq!(flags, [("x", true), ("y", true)]); // marker in the middle of the hunk, and at the end
    let b = one(&files, "b.txt");
    let flags: Vec<_> = b.hunks[0].lines.iter().map(|l| (l.kind, l.text.as_str(), l.no_newline)).collect();
    assert_eq!(
        flags,
        [(Kind::Context, "keep", false), (Kind::Del, "x", true), (Kind::Add, "x", false), (Kind::Add, "more", false)]
    );
    // The \r stays, so line text matches the blob byte for byte.
    assert_eq!(
        lines(&one(&files, "crlf.txt"))[1..],
        [(Kind::Del, Some(2), None, "b\r".into()), (Kind::Add, None, Some(2), "B\r".into())]
    );
}

#[test]
fn awkward_names() {
    let names = ["a b.txt", "é.txt", "q\"uo.txt", "back\\slash.txt", "tab\there.txt", "x é y.txt", "diff --git a b"];
    let files = changed("names", &names.map(|n| (n, "1\n")), |d| names.iter().for_each(|n| write(d, n, "2\n")));
    for n in names {
        let f = one(&files, n);
        assert_eq!((f.status, f.stats()), (Status::Modified, (1, 1)), "{n}");
    }
}

#[test]
fn content_that_looks_like_headers() {
    let patch = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n";
    let files = changed("meta", &[("p.diff", patch)], |d| write(d, "p.diff", &patch.replace("@@ -1", "@@ -2")));
    assert_eq!(files.len(), 1);
    let f = one(&files, "p.diff");
    assert_eq!(f.stats(), (1, 1));
    assert!(lines(&f).iter().any(|(k, _, _, t)| *k == Kind::Context && t == "diff --git a/x b/x"));
}

#[test]
fn user_config_does_not_change_the_result() {
    let make = |cfg: &[(&str, &str)]| {
        let r = repo(
            "cfg",
            &[("a b.txt", TEN), ("é.txt", TEN), ("old.txt", TEN), ("blank.txt", "a\n\nb\n"), ("b.bin", "\0")],
        );
        for (k, v) in cfg {
            git(&r.0, &["config", k, v]);
        }
        write(&r.0, "a b.txt", &TEN.replace('5', "five"));
        write(&r.0, "é.txt", &TEN.replace('9', "nine"));
        write(&r.0, "blank.txt", "A\n\nb\n");
        // Named only by the `diff --git` line, where prefixes and quoting matter most.
        write(&r.0, "b.bin", "\0\x01");
        std::fs::set_permissions(r.0.join("é.txt"), PermissionsExt::from_mode(0o755)).unwrap();
        git(&r.0, &["mv", "old.txt", "new.txt"]);
        git(&r.0, &["add", "-A"]);
        git(&r.0, &["commit", "-qm", "c"]);
        let spec = Spec::Range { base: "HEAD~1".into(), head: "HEAD".into(), merge_base: false };
        let files = Review::open(&r.0, &spec).unwrap().files;
        let key = |f: &File| (f.path.clone(), f.old_path.clone(), f.status, f.new_mode.clone(), f.binary, lines(f));
        files.iter().map(key).collect::<Vec<_>>()
    };
    let plain = make(&[]);
    for cfg in [
        ("diff.noprefix", "true"),
        ("diff.mnemonicPrefix", "true"),
        ("diff.renames", "false"),
        ("core.quotePath", "false"),
        ("diff.suppressBlankEmpty", "true"),
        ("diff.external", "false"),
        ("diff.context", "0"),
        ("diff.relative", "true"),
        ("color.ui", "always"),
    ] {
        assert_eq!(make(&[cfg]), plain, "{cfg:?}");
    }
}

#[test]
fn worktree_mode_is_parsed_too() {
    let r = repo("wtdiff", &[("a.txt", "a\n")]);
    write(&r.0, "a.txt", "b\n");
    let files = Review::open(&r.0, &Spec::default()).unwrap().files;
    let f = one(&files, "a.txt");
    assert_eq!((f.status, f.stats()), (Status::Modified, (1, 1)));
}

#[test]
fn hand_made_input_never_panics() {
    assert!(parse("").is_empty());
    for text in [
        "diff --git a/x b/x\n@@ -1,2 +1,2 @@\n", // hunk cut short
        "diff --git a/x b/x\n@@ -zz +1 @@\n+a\n",
        "diff --git a/x b/x\n@@ -1 +1\n",
        "diff --git \"a/\\3\" \"b/\\", // broken escapes, no newline at end
        "diff --git \"a/unterminated\n",
        "diff --git\n",
        "\\ No newline at end of file\n",
        "+orphan line\n",
        "diff --git a/x b/x\n--- \"a/x\\\n+++ b/x\t\n@@ -1 +1 @@\n-a\n+b\n\\\n\\\n",
    ] {
        let _ = parse(text);
    }
    let f = &parse("diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n")[0];
    assert_eq!((f.path.as_str(), f.stats()), ("x", (1, 1)));
}

#[test]
fn octal_escapes_decode_to_utf8() {
    let f = &parse(
        "diff --git \"a/\\355\\225\\234 \\\"q\\\\.txt\" \"b/\\355\\225\\234 \\\"q\\\\.txt\"\nnew file mode 100644\nindex 0000000..1111111\n",
    )[0];
    assert_eq!((f.path.as_str(), f.status), ("한 \"q\\.txt", Status::Added));
}

#[test]
fn hostile_hunk_headers() {
    // Near u32::MAX the line counter would overflow: the hunk is rejected, not wrapped.
    let f = &parse("diff --git a/x b/x\n@@ -4294967295 +1 @@\n x\n")[0];
    assert!(f.hunks.is_empty());
    // A bad header later in a file keeps the good hunks before it.
    let f = &parse("diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b\n@@ -zz +1 @@\n+c\n")[0];
    assert_eq!(f.stats(), (1, 1));
    // A hunk cut short gets no phantom line from the text's final newline.
    let f = &parse("diff --git a/x b/x\n@@ -1,2 +1,2 @@\n")[0];
    assert!(f.hunks[0].lines.is_empty());
}

#[test]
fn multiple_hunks_and_sections() {
    let body: String = (1..=30).map(|i| format!("{i}\n")).collect();
    let src = format!("fn main() {{\n{body}}}\n");
    let files = changed("hunks", &[("m.rs", &src)], |d| {
        write(d, "m.rs", &src.replace("\n3\n", "\nthree\n").replace("\n28\n", "\n"))
    });
    let f = one(&files, "m.rs");
    let h: Vec<_> =
        f.hunks.iter().map(|h| (h.old_start, h.old_len, h.new_start, h.new_len, h.section.as_str())).collect();
    assert_eq!(h, [(1, 7, 1, 7, ""), (26, 7, 26, 6, "fn main() {")]);
    let del = lines(&f).into_iter().find(|l| l.0 == Kind::Del && l.3 == "28").unwrap();
    assert_eq!((del.1, del.2), (Some(29), None));
}

#[test]
fn names_that_are_not_utf8_decode_lossily() {
    let f = &parse("diff --git \"a/\\377x\" \"b/\\377x\"\nindex 1111111..2222222 100644\n")[0];
    assert_eq!(f.path, "\u{FFFD}x");
}

#[test]
fn row_count_matches_rows() {
    let files = changed("rows", &[("a.txt", TEN), ("b.dat", "\0"), ("run.sh", "x\n"), ("gone.txt", "g\n")], |d| {
        write(d, "a.txt", &TEN.replace('2', "two").replace("9", "nine"));
        write(d, "b.dat", "\0\x01");
        std::fs::set_permissions(d.join("run.sh"), PermissionsExt::from_mode(0o755)).unwrap();
        std::fs::remove_file(d.join("gone.txt")).unwrap();
        write(d, "empty.txt", "");
        write(d, "eof.txt", "no newline");
    });
    for f in &files {
        // Any window of rows is the same slice of the whole.
        let all = f.rows(0, usize::MAX);
        for (from, n) in [(0, 1), (1, 2), (2, 3), (3, 100), (all.len() - 1, 5), (all.len(), 5)] {
            let want = &all[from.min(all.len())..(from + n).min(all.len())];
            assert_eq!(f.rows(from, n), want, "{} {from}+{n}", f.path);
        }
        let rows = f.rows(0, usize::MAX);
        assert_eq!(rows.len(), f.row_count(), "{}: {rows:?}", f.path);
        assert_eq!(rows[0], serde_json::json!(["f"]), "{}", f.path);
    }
    // Files without hunks say why in one note row.
    let note = |p: &str| one(&files, p).rows(0, usize::MAX)[1].clone();
    assert_eq!(note("b.dat"), serde_json::json!(["n", "Binary file"]));
    assert_eq!(note("run.sh"), serde_json::json!(["n", "Mode 100644 → 100755"]));
    assert_eq!(note("empty.txt"), serde_json::json!(["n", "No content changes"]));
    // The no-newline marker is a flag on its line, not a row.
    assert_eq!(one(&files, "eof.txt").rows(0, usize::MAX)[2], serde_json::json!(["+", null, 1, "no newline", 1]));
}
