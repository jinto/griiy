# Contributing

## Build and check

CI (`.github/workflows/ci.yml`) runs exactly these; run them before opening a PR:

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
cargo build --release
! grep -rnE '\.(unwrap|expect)\(' src/   # no panics in app code; tests live in tests/
```

`./bench.sh <repo> [runs] [range]` measures launch-to-first-paint and memory against a real repository.

## Layout

- `src/` app code (`lib.rs` modules, `main.rs` window wiring), `src/app/` the embedded frontend (plain ES, no build step)
- `tests/` integration tests; `tests/common` builds throwaway git repos
- `docs/PRD.md` what and why, `docs/TASKS.md` the work list with done criteria

## Rules of thumb

- No panics outside tests: show an error screen instead (`git::Error`).
- The frontend reaches the backend only through `griiy://` routes in `protocol.rs`; files are addressed by ID, never by path.
- New dependencies need a reason; prefer std.

## Repository settings (maintainers)

To make CI block merges, protect `main` in GitHub settings: require a pull request and require the
`check` status check to pass.

By contributing you agree your work is dual-licensed under MIT OR Apache-2.0.
