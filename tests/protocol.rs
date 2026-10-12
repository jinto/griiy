mod common;

use common::{repo, write};
use griiy::{args::Spec, git::Review, protocol::handle};
use serde_json::Value;
use wry::http::Uri;

fn get(url: &str, review: Option<&Review>) -> (u16, String, Vec<u8>) {
    let res = handle(&url.parse::<Uri>().unwrap(), review);
    let mime = res.headers().get("Content-Type").map(|v| v.to_str().unwrap().to_string()).unwrap_or_default();
    (res.status().as_u16(), mime, res.body().to_vec())
}

#[test]
fn serves_embedded_assets_with_mime_types() {
    let root = env!("CARGO_MANIFEST_DIR");
    for (file, mime) in [
        ("index.html", "text/html; charset=utf-8"),
        ("app.js", "text/javascript; charset=utf-8"),
        ("app.css", "text/css; charset=utf-8"),
    ] {
        let (status, got, body) = get(&format!("griiy://app/{file}"), None);
        assert_eq!((status, got.as_str()), (200, mime), "{file}");
        // Same bytes as the source file: the frontend is compiled into the binary.
        assert_eq!(body, std::fs::read(format!("{root}/src/app/{file}")).unwrap(), "{file}");
    }
}

#[test]
fn rejects_everything_outside_the_allowlist() {
    for url in [
        "griiy://app/../Cargo.toml",
        "griiy://app/%2e%2e/Cargo.toml",
        "griiy://app/%2E%2E%2Fsrc%2Fmain.rs",
        "griiy://app/index.html%00",
        "griiy://app/%00",
        "griiy://app//etc/passwd",
        "griiy://app/Users/Shared",
        "griiy://app/src/app/app.js",
        "griiy://app/",
        "griiy://app/index.html?x=1",
        "griiy://app:80/index.html",
        "griiy://u@app/index.html",
        "griiy://other/index.html",
        "https://app/index.html",
        "griiy://api/../app/index.html",
    ] {
        assert_eq!(get(url, None).0, 404, "{url}");
    }
}

#[test]
fn files_are_reachable_only_by_id() {
    let r = repo("proto", &[("한글 파일.txt", "a\n"), ("a b.txt", "a\n"), ("plain.txt", "a\n")]);
    for f in ["한글 파일.txt", "a b.txt", "plain.txt"] {
        write(&r.0, f, "a\nchanged\n");
    }
    let review = Review::open(&r.0, &Spec::default()).unwrap();
    assert_eq!(review.files.len(), 3);
    for (id, path) in review.files.iter().map(|f| &f.path).enumerate() {
        let res = handle(&format!("griiy://api/diff?id={id}").parse::<Uri>().unwrap(), Some(&review));
        assert_eq!(res.status(), 200, "{path}");
        assert_eq!(res.headers()["Content-Type"], "application/json");
        assert_eq!(res.headers()["Access-Control-Allow-Origin"], "griiy://app");
        let v: Value = serde_json::from_slice(res.body()).unwrap();
        // File header, hunk header, then the lines: [kind, old, new, text].
        let rows = v["rows"].as_array().unwrap();
        assert_eq!(rows.len(), review.files[id].row_count(), "{path}: {v}");
        assert_eq!((rows[0][0].as_str(), rows[1][0].as_str()), (Some("f"), Some("h")), "{path}: {v}");
        assert_eq!(rows[3], serde_json::json!(["+", null, 2, "changed"]), "{path}: {v}");
    }
    let n = review.files.len();
    for url in [
        format!("griiy://api/diff?id={n}"),
        "griiy://api/diff".into(),
        "griiy://api/diff?id=".into(),
        "griiy://api/diff?id=-1".into(),
        "griiy://api/diff?id=%30".into(),
        "griiy://api/diff?id=0%00".into(),
        "griiy://api/diff?id=0&ref=main".into(),
        "griiy://api/diff?ref=main&id=0".into(),
        "griiy://api/diff?path=plain.txt".into(),
        "griiy://api/diff?id=../plain.txt".into(),
        "griiy://api/diff?id=99999999999999999999999".into(),
        "griiy://api/file?id=0".into(),
        "griiy://api/diff/../diff?id=0".into(),
    ] {
        let res = handle(&url.parse::<Uri>().unwrap(), Some(&review));
        assert_eq!(res.status(), 404, "{url}");
        assert_eq!(res.headers()["Access-Control-Allow-Origin"], "griiy://app", "{url}");
    }
    // No review (error screen): the API has nothing to serve.
    assert_eq!(get("griiy://api/diff?id=0", None).0, 404);
}

#[test]
fn tracked_files_come_after_first_paint() {
    let r = repo("tracked", &[("a.txt", "a\n"), ("d/b.txt", "b\n")]);
    let review = Review::open(&r.0, &Spec::default()).unwrap();
    let (status, _, body) = get("griiy://api/tracked", Some(&review));
    let v: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!((status, v["tracked"].as_str()), (200, Some("a.txt\nd/b.txt\n")));
    assert_eq!(get("griiy://api/tracked", None).0, 404);
    assert_eq!(get("griiy://api/tracked?x=1", Some(&review)).0, 404);
}

#[test]
fn diff_rows_come_in_windows() {
    let r = repo("window", &[("a.txt", &(0..50).map(|i| format!("{i}\n")).collect::<String>())]);
    write(&r.0, "a.txt", &(0..50).map(|i| format!("{}\n", i * 3)).collect::<String>());
    let review = Review::open(&r.0, &Spec::default()).unwrap();
    let rows = |url: &str| {
        let (status, _, body) = get(url, Some(&review));
        assert_eq!(status, 200, "{url}");
        serde_json::from_slice::<Value>(&body).unwrap()["rows"].clone()
    };
    let all = review.files[0].rows(0, usize::MAX);
    assert_eq!(rows("griiy://api/diff?id=0"), serde_json::json!(all));
    assert_eq!(rows("griiy://api/diff?id=0&from=10&n=5"), serde_json::json!(all[10..15]));
    assert_eq!(rows("griiy://api/diff?id=0&from=9999&n=5"), serde_json::json!([]));
    for url in ["griiy://api/diff?id=0&n=5", "griiy://api/diff?id=0&from=1&n=2&x=3", "griiy://api/diff?id=0&from=-1"] {
        assert_eq!(get(url, Some(&review)).0, 404, "{url}");
    }
}
