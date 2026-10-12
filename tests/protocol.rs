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
    for (id, path) in review.files.iter().enumerate() {
        let res = handle(&format!("griiy://api/diff?id={id}").parse::<Uri>().unwrap(), Some(&review));
        assert_eq!(res.status(), 200, "{path}");
        assert_eq!(res.headers()["Content-Type"], "application/json");
        assert_eq!(res.headers()["Access-Control-Allow-Origin"], "griiy://app");
        let v: Value = serde_json::from_slice(res.body()).unwrap();
        assert_eq!(v["path"], path.as_str());
        let text = v["text"].as_str().unwrap();
        assert!(text.contains("+changed"), "{path}: {text}");
        assert!(!text.contains("diff --git a/plain.txt") || path == "plain.txt", "one file only: {text}");
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
