# griiy

A small, fast macOS app for reviewing changes. Point it at a range or a PR, read the diff,
and (soon) select lines and ask *"why did this change?"*, answered with citations to commits,
PR comments and issues.

> Status: early. Today griiy opens your working-tree changes or a commit range in a window with a
> file tree. GitHub PRs and AI questions are in progress
> ([PRD](docs/PRD.md), [tasks](docs/TASKS.md)).

## Install

Requires macOS 15+ and git. Build from source with Xcode 26 (Swift 6.2+):

```sh
scripts/bundle.sh --install   # builds griiy.app and links /usr/local/bin/griiy to it
```

Homebrew and a signed, notarized app will come with the first release.

## Use

```sh
griiy                    # uncommitted changes (staged and unstaged) vs HEAD
griiy main               # working tree vs main
griiy main..feature      # feature vs main, endpoint to endpoint
griiy main...feature     # what feature changed since it branched off main (like a PR)
griiy -C path/to/repo    # another repository; combines with any of the above
```

Ranges mean what they mean to `git diff`; a missing side is `HEAD`. Untracked files are not shown.

Planned (v0.1): `griiy https://github.com/o/r/pull/42`, `griiy '#42'`.

## Where griiy stores data

| What | Where |
|---|---|
| Settings | `~/Library/Application Support/griiy/config.toml` |
| Per-review data: seen files; *(planned)* questions and answers, **including snapshots of the code you asked about** | `~/Library/Application Support/griiy/reviews/<key>.json` |
| Fetched PR refs *(planned)* | `refs/griiy/*` in your repository. griiy writes nothing else to your repo |
| Secrets: tokens, API keys *(planned)* | macOS Keychain, service `griiy`. Never in the files above |

Delete a review's file to forget it; delete the folder to forget everything.

### Settings

All keys are optional. A bad value falls back to its default with a warning. Most settings are read now but used by features still in progress.

```toml
context_lines = 40          # lines of context sent around a question (0–1000)
token_limit = 100000        # max tokens sent per question (1000–1000000)
large_file_bytes = 1048576  # diffs above this start collapsed

[ai]
backend = "auto"            # "auto" (claude CLI if on PATH, else API), "claude-cli", "api"
model = "claude-opus-5-5"
```

## What griiy sends over the network

Nothing, unless you use a feature that needs it. Without AI or PRs, griiy works fully offline.

| When | To | What |
|---|---|---|
| You ask a question (after you agree on first use) | Anthropic, through the `claude` CLI or the API | Your question and the evidence shown in the preview: selected code with nearby lines, related commit messages and history, PR text and comments |
| You open a GitHub PR | GitHub, through `gh` and `git fetch` | PR metadata, comments and linked issues; the PR's commits |
| (v0.2) Bitbucket Cloud PR, Jira ticket | Bitbucket, your Jira host | The same, for those services |
| You click "show image" in a PR description | The image's host | An image request |

No telemetry, no accounts, no griiy servers.

## License

Licensed under either of [Apache License 2.0](LICENSE-APACHE) or [MIT](LICENSE-MIT) at your option.
Contributions are dual-licensed the same way unless you state otherwise.
