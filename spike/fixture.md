# PR #42: Make the parser faster

This PR **speeds up** parsing by caching `Hunk` headers. See [the issue](https://github.com/o/r/issues/7) and [docs](mailto:dev@example.com).

## Checklist
- [x] tests pass
- [ ] benchmark on a 120k-line diff
- plain bullet with `inline code`

## Numbers

| case | before | after |
|---|---:|---:|
| small | 0.8s | 0.5s |
| 120k lines | 2.9s | 0.6s |

```rust
fn parse(text: &str) -> Vec<File> {
    text.split('\n').collect() // <script>alert(1)</script> inside code stays text
}
```

> Quoted: reviewers asked about memory.

## Hostile content (must render as harmless text or be dropped)
<script>alert('xss')</script>
<img src="https://tracker.example.com/pixel.gif" onerror="alert(1)">
<iframe src="https://evil.example.com"></iframe>
[click me](javascript:alert(1)) · [data link](data:text/html,<script>alert(1)</script>) · [file link](file:///etc/passwd)
![external image](https://tracker.example.com/beacon.png)
<b>raw bold tag</b> and &lt;escaped&gt; entities.
