mod common;

use griiy::config::{Backend, Config, load};

fn with(text: &str) -> (Config, Vec<String>) {
    let t = common::TempDir::new("config");
    let p = t.0.join("config.toml");
    std::fs::write(&p, text).unwrap();
    load(&p)
}

#[test]
fn missing_or_empty_file_is_defaults() {
    let t = common::TempDir::new("config-missing");
    assert_eq!(load(&t.0.join("nope.toml")), (Config::default(), vec![]));
    assert_eq!(with(""), (Config::default(), vec![]));
    assert_eq!(with("# only a comment\n"), (Config::default(), vec![]));
}

#[test]
fn valid_values_are_used() {
    let (c, w) = with(
        "context_lines = 10\ntoken_limit = 50000\nlarge_file_bytes = 2048\n[ai]\nbackend = \"api\"\nmodel = \"claude-sonnet-5-5\"\n",
    );
    assert!(w.is_empty(), "{w:?}");
    assert_eq!(
        c,
        Config {
            backend: Backend::Api,
            model: "claude-sonnet-5-5".into(),
            context_lines: 10,
            token_limit: 50_000,
            large_file_bytes: 2048
        }
    );
}

#[test]
fn bad_values_fall_back_with_a_warning_each() {
    let (c, w) = with(
        "context_lines = \"forty\"\ntoken_limit = 5\nlarge_file_bytes = -1\ncolour = true\n[ai]\nbackend = \"gpt\"\nmodel = 3\nextra = 1\n",
    );
    assert_eq!(c, Config::default());
    assert_eq!(w.len(), 7, "{w:#?}");
    for key in ["context_lines", "token_limit", "large_file_bytes", "colour", "ai.backend", "ai.model", "ai.extra"] {
        assert!(w.iter().any(|m| m.contains(key)), "no warning for {key}: {w:#?}");
    }
    // One bad value doesn't spoil its neighbours.
    let (c, w) = with("context_lines = 1.5\ntoken_limit = 2000\nai = \"claude\"\n");
    assert_eq!((c.context_lines, c.token_limit, w.len()), (40, 2000, 2), "{w:?}");
}

#[test]
fn syntax_error_is_defaults_with_a_warning() {
    let (c, w) = with("context_lines = \n[[[");
    assert_eq!(c, Config::default());
    assert_eq!(w.len(), 1);
}
