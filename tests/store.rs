mod common;

use common::{TempDir, git, repo};
use griiy::store::{Source, Store, review_key};
use serde_json::json;
use std::path::Path;

#[test]
fn keys() {
    let gh = |owner, repo, number| review_key(&Source::GitHub { owner, repo, number });
    assert_eq!(gh("Octo", "Hello.World", 42), "gh-octo-hello.world-42");
    assert_ne!(gh("a-b", "c", 1), gh("a", "b-c", 1), "`-` inside a name can't fake a separator");

    let repo = Path::new("/Users/me/src/app");
    let range = review_key(&Source::Range { repo, base: "main", head: "feature/x" });
    assert!(range.starts_with("local-") && range.ends_with("-main-feature%2Fx"), "{range}");
    let tree = review_key(&Source::WorkTree { repo });
    assert_eq!(tree, format!("{}-worktree", &range[..range.len() - "-main-feature%2Fx".len()]));
    assert_ne!(tree, review_key(&Source::WorkTree { repo: Path::new("/Users/me/src/other") }));

    let long = "x/".repeat(300);
    let k = review_key(&Source::Range { repo, base: "main", head: &long });
    assert!(k.len() <= 200 && !k.contains('/'), "{k}");
    let k2 = review_key(&Source::Range { repo, base: "main", head: &format!("{long}y") });
    assert_ne!(k, k2, "long keys stay distinct");
}

#[test]
fn local_range_key_survives_a_new_commit() {
    let r = repo("key", &[("a.txt", "a\n")]);
    git(&r.0, &["checkout", "-qb", "feature"]);
    common::write(&r.0, "sub/b.txt", "b\n");
    git(&r.0, &["add", "-A"]);
    git(&r.0, &["commit", "-qm", "b"]);
    let top = |dir: &Path| git(dir, &["rev-parse", "--show-toplevel"]).trim_end().to_string();
    let key = |dir: &Path| review_key(&Source::Range { repo: Path::new(&top(dir)), base: "main", head: "feature" });
    let before = key(&r.0);
    common::write(&r.0, "a.txt", "changed\n");
    git(&r.0, &["commit", "-qam", "more"]);
    assert_eq!(key(&r.0), before);
    assert_eq!(key(&r.0.join("sub")), before, "same key from a subdirectory");
    let link = r.0.with_extension("link");
    std::os::unix::fs::symlink(&r.0, &link).unwrap();
    let via_link = review_key(&Source::Range { repo: &link, base: "main", head: "feature" });
    std::fs::remove_file(&link).unwrap();
    assert_eq!(via_link, before, "same key through a symlink");
}

#[test]
fn save_then_load() {
    let t = TempDir::new("store");
    let store = Store::new(t.0.join("reviews"));
    assert_eq!(store.load("k").unwrap(), json!({ "version": 1 }), "missing → fresh");
    let doc = json!({ "version": 1, "seen": { "a.txt": "blob" } });
    store.save("k", &doc).unwrap();
    store.save("k", &doc).unwrap();
    assert_eq!(store.load("k").unwrap(), doc);
    let names: Vec<_> = std::fs::read_dir(t.0.join("reviews")).unwrap().map(|e| e.unwrap().file_name()).collect();
    assert_eq!(names, ["k.json"], "no temp files left behind");
    store.save("n", &json!({ "seen": {} })).unwrap();
    assert_eq!(store.load("n").unwrap(), json!({ "version": 1, "seen": {} }), "version stamped on save");
}

#[test]
fn corrupt_files_are_backed_up() {
    let t = TempDir::new("corrupt");
    let store = Store::new(&t.0);
    for (i, bad) in
        ["{not json", "", "[1,2]", r#"{"seen":{}}"#, r#"{"version":99}"#, r#"{"version":"1"}"#].iter().enumerate()
    {
        let key = format!("k{i}");
        std::fs::write(t.0.join(format!("{key}.json")), bad).unwrap();
        assert_eq!(store.load(&key).unwrap(), json!({ "version": 1 }), "{bad:?}");
        let backups: Vec<_> = std::fs::read_dir(&t.0)
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p.file_name().unwrap().to_str().unwrap().starts_with(&format!("{key}.json.corrupt-")))
            .collect();
        assert_eq!(backups.len(), 1, "{bad:?}");
        assert_eq!(std::fs::read_to_string(&backups[0]).unwrap(), *bad, "original kept");
        assert!(!t.0.join(format!("{key}.json")).exists());
    }
}
