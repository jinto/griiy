//! `griiy://` (PRD §7.3): `griiy://app/<asset>` serves embedded files, `griiy://api/<route>` serves JSON.
//! Everything else is 404. Nothing here reads a path from the URL: assets are an exact-match table
//! and repository files are addressed only by their ID in the current review.

use crate::git::Review;
use serde_json::{Value, json};
use std::borrow::Cow;
use wry::http::{HeaderValue, Response, StatusCode, Uri};

type Body = Cow<'static, [u8]>;

const HTML: &str = "text/html; charset=utf-8";
const JS: &str = "text/javascript; charset=utf-8";
const CSS: &str = "text/css; charset=utf-8";
const JSON: &str = "application/json";

const ASSETS: &[(&str, &str, &[u8])] = &[
    ("/index.html", HTML, include_bytes!("app/index.html")),
    ("/app.js", JS, include_bytes!("app/app.js")),
    ("/app.css", CSS, include_bytes!("app/app.css")),
];

/// `review` is `None` until the review is open, and when it failed (the page shows the error).
pub fn handle(uri: &Uri, review: Option<&Review>) -> Response<Body> {
    if uri.scheme_str() != Some("griiy") {
        return not_found();
    }
    // Comparing the whole authority also rejects ports and userinfo.
    match uri.authority().map(|a| a.as_str()) {
        Some("app") if uri.query().is_none() => match ASSETS.iter().find(|(p, ..)| *p == uri.path()) {
            Some((_, mime, bytes)) => respond(StatusCode::OK, mime, Cow::Borrowed(*bytes)),
            None => not_found(),
        },
        Some("api") => api(uri.path(), uri.query(), review),
        _ => not_found(),
    }
}

fn api(path: &str, query: Option<&str>, review: Option<&Review>) -> Response<Body> {
    match (path, review) {
        ("/diff", Some(r)) => {
            // `id=N`, optionally `&from=M&n=K`: a window of the file's rows (all of them by default).
            let window = query.and_then(|q| {
                let mut p = q.split('&');
                let id = parse_id(p.next()?.strip_prefix("id=")?)?;
                let (from, n) = match (p.next(), p.next(), p.next()) {
                    (None, ..) => (0, usize::MAX),
                    (Some(f), Some(n), None) => (parse_id(f.strip_prefix("from=")?)?, parse_id(n.strip_prefix("n=")?)?),
                    _ => return None,
                };
                Some((id, from, n))
            });
            match window.and_then(|(id, from, n)| Some((r.file_diff(id)?, from, n))) {
                Some((f, from, n)) => api_json(StatusCode::OK, json!({ "rows": f.rows(from, n) })),
                None => api_json(StatusCode::NOT_FOUND, json!({ "error": "not found" })),
            }
        }
        ("/tracked", Some(r)) if query.is_none() => api_json(StatusCode::OK, json!({ "tracked": r.tracked })),
        _ => api_json(StatusCode::NOT_FOUND, json!({ "error": "not found" })),
    }
}

/// ASCII digits only, taken raw (no percent-decoding), so `1%00`, `-1`, `+1`, `1&ref=x` all fail.
fn parse_id(s: &str) -> Option<usize> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

fn api_json(status: StatusCode, v: Value) -> Response<Body> {
    let mut res = respond(status, JSON, Cow::Owned(v.to_string().into_bytes()));
    // The page's origin is griiy://app; without this WebKit rejects the cross-host fetch.
    res.headers_mut().insert("Access-Control-Allow-Origin", HeaderValue::from_static("griiy://app"));
    res
}

fn not_found() -> Response<Body> {
    respond(StatusCode::NOT_FOUND, "text/plain; charset=utf-8", Cow::Borrowed(b"not found"))
}

fn respond(status: StatusCode, mime: &str, body: Body) -> Response<Body> {
    Response::builder().status(status).header("Content-Type", mime).body(body).unwrap_or_default()
}
