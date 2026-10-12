mod common;

use griiy::events::{Channel, Outbox};
use serde_json::{Value, json};
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

/// Decode the batch back out of `window.griiy.recv([...])`.
fn batch(script: &str) -> Vec<Value> {
    let json = script.strip_prefix("window.griiy.recv(").and_then(|s| s.strip_suffix(')')).unwrap();
    serde_json::from_str(json).unwrap()
}

#[test]
fn queues_until_ready_then_delivers_in_order() {
    let mut out = Outbox::new(1_000);
    for i in 0..100 {
        out.push(1, "item", json!(i));
    }
    assert_eq!(out.drain(), None, "nothing before ready");
    out.set_ready();
    let msgs = batch(&out.drain().unwrap());
    assert_eq!(msgs.len(), 100);
    for (i, m) in msgs.iter().enumerate() {
        assert_eq!(m, &json!({ "v": 1, "req": 1, "type": "item", "data": i }));
    }
    assert!(out.is_empty() && out.drain().is_none());
}

#[test]
fn a_flood_is_merged_within_the_cap() {
    let mut out = Outbox::new(100);
    let mut want = [String::new(), String::new()];
    // Two interleaved streams, 10,000 chunks in total.
    for i in 0..10_000 {
        let (req, s) = (i % 2, format!("<{i}>"));
        want[req].push_str(&s);
        out.push(req as u64, "chunk", json!(s));
        assert!(out.len() <= 100);
    }
    out.set_ready();
    let mut got = [String::new(), String::new()];
    for m in batch(&out.drain().unwrap()) {
        got[m["req"].as_u64().unwrap() as usize].push_str(m["data"].as_str().unwrap());
    }
    assert_eq!(got, want, "every chunk arrives, in order per request");
}

#[test]
fn awkward_data_survives_the_script() {
    let nasty = "</script><script>alert(1)</script>\n\r\"'`\\ ${x} \u{2028}\u{2029} \0 한글";
    let mut out = Outbox::new(10);
    out.push(3, "chunk", json!(nasty));
    out.set_ready();
    let script = out.drain().unwrap();
    assert!(!script.contains('\n'), "one line of JS");
    assert_eq!(batch(&script)[0]["data"], nasty);
}

#[test]
fn wakes_once_per_pending_batch() {
    let wakes = Arc::new(AtomicUsize::new(0));
    let w = wakes.clone();
    let ch = Channel::new(100, move || {
        w.fetch_add(1, Ordering::SeqCst);
    });
    ch.send(1, "item", json!(0));
    assert_eq!(wakes.load(Ordering::SeqCst), 0, "not ready yet");
    ch.ready();
    for i in 0..10 {
        ch.send(1, "item", json!(i));
    }
    assert_eq!(wakes.load(Ordering::SeqCst), 1);
    assert_eq!(batch(&ch.take_script().unwrap()).len(), 11);
    ch.send(1, "item", json!(0));
    assert_eq!(wakes.load(Ordering::SeqCst), 2);
}

#[test]
fn cancel_stops_the_producer() {
    let ch = Channel::new(100, || {});
    ch.ready();
    let stop = ch.start(7);
    let producer = {
        let ch = ch.clone();
        thread::spawn(move || {
            let mut n = 0;
            while !stop.load(Ordering::Relaxed) {
                ch.send(7, "chunk", json!("x"));
                n += 1;
                thread::sleep(Duration::from_millis(1));
            }
            n
        })
    };
    thread::sleep(Duration::from_millis(20));
    ch.cancel(7);
    let t = Instant::now();
    assert!(producer.join().unwrap() > 0);
    assert!(t.elapsed() < Duration::from_secs(1));
}

#[test]
fn closing_the_window_cancels_everything() {
    let ch = Channel::new(100, || {});
    let flags: Vec<_> = (0..3).map(|r| ch.start(r)).collect();
    ch.cancel_all();
    assert!(flags.iter().all(|f| f.load(Ordering::Relaxed)));
}

/// A fake git that starts a grandchild holding the pipes, like `git fetch` starting ssh.
fn slow_git(dir: &std::path::Path) -> std::path::PathBuf {
    let fake = dir.join("slow-git");
    std::fs::write(&fake, "#!/bin/sh\nsleep 30 &\nwait\n").unwrap();
    std::fs::set_permissions(&fake, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    fake
}

#[test]
fn cancel_and_window_close_kill_running_git_and_its_children() {
    let dir = common::TempDir::new("cancel");
    let fake = slow_git(&dir.0);
    let ch = Channel::new(100, || {});
    let workers: Vec<_> = [1, 2]
        .map(|req| {
            let flag = ch.start(req);
            let (fake, dir) = (fake.clone(), dir.0.clone());
            thread::spawn(move || griiy::git::run(fake.to_str().unwrap(), &dir, &[], Some(&flag)))
        })
        .into();
    thread::sleep(Duration::from_millis(200));
    let t = Instant::now();
    ch.cancel(1);
    ch.cancel_all();
    for w in workers {
        assert_eq!(w.join().unwrap(), Err(griiy::git::Error::Cancelled));
    }
    assert!(t.elapsed() < Duration::from_secs(2), "grandchildren held the pipes: {:?}", t.elapsed());
}
