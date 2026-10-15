# Contributing

## Build and check

Requires macOS 15+ and Xcode 26 (Swift 6.2+). CI (`.github/workflows/ci.yml`) runs exactly these;
run them before opening a PR:

```sh
swift format lint --strict --recursive Sources Tests
swift build -c release -Xswiftc -warnings-as-errors
swift test
! grep -rnE 'fatalError|precondition\(|unsafelyUnwrapped' Sources/   # no crashes in app code
```

`swift format` also forbids force unwraps (`!`), `try!` and implicitly unwrapped optionals in
`Sources/` (`.swift-format`); tests turn those rules off (`Tests/.swift-format`).

Scripts:
- `scripts/bundle.sh [--install]` builds `.build/griiy.app` (ad hoc signed) and with `--install`
  links `/usr/local/bin/griiy` to it.
- `scripts/bench.sh <rounds> <name=binary>... -- <repo[:range]>...` measures launch-to-first-paint,
  physical footprint and scroll frame times against real repositories, one JSON line per run. CI runs it on a
  generated 150k-line diff and keeps the lines as the `bench` artifact (reference only, never fails the check).
- `scripts/smoke-quit.sh` checks that quitting while git runs leaves no git behind.
- `scripts/winid.swift <pid>` prints the id of a process's main window, for `screencapture -l <id>` (capture
  the griiy window, never the whole screen).

## Layout

- `Sources/GriiyCore/` everything but the window: arguments, git, the diff parser, the review,
  store and config. Foundation only.
- `Sources/griiy/` the AppKit app.
- `Tests/GriiyCoreTests/` Swift Testing; `Support.swift` builds throwaway git repos.
- `docs/PRD.md` what and why, `docs/TASKS.md` the work list with done criteria, `docs/PLAN-*.md`
  the plan and review notes of each piece of work.

## Rules of thumb

- No crashes outside tests: show an error screen instead (`GitError`).
- git runs only through `run` in `Git.swift` (own process group, cancellable, pinned
  environment); user-typed revisions reach git only through `resolve`.
- Blocking work (git) runs on a `Thread`, not a `Task`; the UI is `@MainActor`.
- Files are addressed by their index in the review, never by passing a path back to git.
- New dependencies need a reason; prefer Foundation and AppKit.

## Repository settings (maintainers)

To make CI block merges, protect `main` in GitHub settings: require a pull request and require the
`check` status check to pass.

By contributing you agree your work is dual-licensed under MIT OR Apache-2.0.
