pub mod args;
pub mod config;
pub mod events;
pub mod git;
pub mod protocol;
pub mod store;

/// `~/Library/Application Support/griiy` (PRD §6.6, §7.4).
pub fn app_dir() -> Option<std::path::PathBuf> {
    std::env::var_os("HOME").map(|h| std::path::Path::new(&h).join("Library/Application Support/griiy"))
}
