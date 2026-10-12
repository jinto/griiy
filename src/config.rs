//! `config.toml` (PRD §6.6). Bad values fall back to their default with a warning; never fatal.

use std::{fs, io::ErrorKind, ops::RangeInclusive, path::Path};
use toml::Value;

#[derive(Debug, Clone, PartialEq)]
pub enum Backend {
    Auto,
    ClaudeCli,
    Api,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    pub backend: Backend,
    pub model: String,
    pub context_lines: u32,
    pub token_limit: u32,
    pub large_file_bytes: u64,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            backend: Backend::Auto,
            model: "claude-opus-5-5".into(),
            context_lines: 40,
            token_limit: 100_000,
            large_file_bytes: 1 << 20,
        }
    }
}

/// Missing or empty file → defaults, no warnings.
pub fn load(path: &Path) -> (Config, Vec<String>) {
    let mut c = Config::default();
    let mut warn = Vec::new();
    let text = match fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == ErrorKind::NotFound => return (c, warn),
        Err(e) => {
            warn.push(format!("{}: {e}", path.display()));
            return (c, warn);
        }
    };
    let table = match text.parse::<toml::Table>() {
        Ok(t) => t,
        Err(e) => {
            warn.push(format!("{}: {}", path.display(), e.message()));
            return (c, warn);
        }
    };
    for (key, v) in &table {
        match key.as_str() {
            "ai" => match v.as_table() {
                Some(ai) => {
                    for (k, v) in ai {
                        match k.as_str() {
                            "backend" => match v.as_str() {
                                Some("auto") => c.backend = Backend::Auto,
                                Some("claude-cli") => c.backend = Backend::ClaudeCli,
                                Some("api") => c.backend = Backend::Api,
                                _ => warn.push(bad("ai.backend", v, "\"auto\", \"claude-cli\" or \"api\"")),
                            },
                            "model" => match v.as_str() {
                                Some(m) if !m.trim().is_empty() => c.model = m.into(),
                                _ => warn.push(bad("ai.model", v, "a model name")),
                            },
                            _ => warn.push(format!("unknown setting ai.{k}")),
                        }
                    }
                }
                None => warn.push(bad("ai", v, "a table")),
            },
            "context_lines" => set(&mut c.context_lines, key, v, 0..=1_000, &mut warn),
            "token_limit" => set(&mut c.token_limit, key, v, 1_000..=1_000_000, &mut warn),
            "large_file_bytes" => set(&mut c.large_file_bytes, key, v, 1..=1 << 30, &mut warn),
            _ => warn.push(format!("unknown setting {key}")),
        }
    }
    (c, warn)
}

fn set<T: TryFrom<i64>>(slot: &mut T, key: &str, v: &Value, range: RangeInclusive<i64>, warn: &mut Vec<String>) {
    match v.as_integer().filter(|n| range.contains(n)).and_then(|n| T::try_from(n).ok()) {
        Some(n) => *slot = n,
        None => warn.push(bad(key, v, &format!("an integer in {}..={}", range.start(), range.end()))),
    }
}

fn bad(key: &str, v: &Value, want: &str) -> String {
    format!("{key} = {v} is invalid (want {want}); using the default")
}
