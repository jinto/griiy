//! Backend → page event channel (PRD §7.3). Every message is one `{v:1, req, type, data}` envelope;
//! batches reach the page as a single `window.griiy.recv([...])` call.

use serde_json::{Value, json};
use std::{
    collections::{HashMap, VecDeque},
    sync::{
        Arc, Mutex, PoisonError,
        atomic::{AtomicBool, Ordering},
    },
};

/// Queue of envelopes held until the page says `ready`. Past `cap`, a string `chunk` is appended
/// to its request's latest message when that is also a chunk, so a flood stays within `cap`
/// while each request's order is kept.
// ponytail: non-chunk messages are never merged or dropped, so they alone can exceed `cap` (they're rare: start/done/error).
pub struct Outbox {
    ready: bool,
    queue: VecDeque<Value>,
    cap: usize,
}

impl Outbox {
    pub fn new(cap: usize) -> Self {
        Outbox { ready: false, queue: VecDeque::new(), cap }
    }

    pub fn push(&mut self, req: u64, kind: &str, data: Value) {
        if self.queue.len() >= self.cap
            && kind == "chunk"
            && let Some(text) = data.as_str()
            && let Some(last) = self.queue.iter_mut().rev().find(|m| m["req"] == req)
            && last["type"] == "chunk"
            && let Some(Value::String(prev)) = last.get_mut("data")
        {
            prev.push_str(text);
            return;
        }
        self.queue.push_back(json!({ "v": 1, "req": req, "type": kind, "data": data }));
    }

    pub fn len(&self) -> usize {
        self.queue.len()
    }

    pub fn is_empty(&self) -> bool {
        self.queue.is_empty()
    }

    pub fn set_ready(&mut self) {
        self.ready = true;
    }

    /// The script delivering everything queued, once the page is ready.
    pub fn drain(&mut self) -> Option<String> {
        if !self.ready || self.queue.is_empty() {
            return None;
        }
        let batch: Vec<Value> = self.queue.drain(..).collect();
        // serde_json output is a valid JS expression (U+2028/9 are legal in strings since ES2019),
        // and evaluate_script isn't parsed as HTML, so `</script>` in data is inert.
        Some(format!("window.griiy.recv({})", Value::Array(batch)))
    }
}

/// Outbox plus per-request cancel flags, shared by worker threads and the event loop.
/// `wake` asks the event loop to call [`Channel::take_script`]; it fires once per pending batch.
pub struct Channel {
    outbox: Mutex<Outbox>,
    cancels: Mutex<HashMap<u64, Arc<AtomicBool>>>,
    pending: AtomicBool,
    wake: Box<dyn Fn() + Send + Sync>,
}

impl Channel {
    pub fn new(cap: usize, wake: impl Fn() + Send + Sync + 'static) -> Arc<Self> {
        Arc::new(Channel {
            outbox: Mutex::new(Outbox::new(cap)),
            cancels: Mutex::default(),
            pending: AtomicBool::new(false),
            wake: Box::new(wake),
        })
    }

    pub fn send(&self, req: u64, kind: &str, data: Value) {
        let mut out = self.outbox.lock().unwrap_or_else(PoisonError::into_inner);
        out.push(req, kind, data);
        if out.ready && !self.pending.swap(true, Ordering::AcqRel) {
            (self.wake)();
        }
    }

    pub fn ready(&self) {
        self.outbox.lock().unwrap_or_else(PoisonError::into_inner).set_ready();
        self.pending.store(true, Ordering::Release);
        (self.wake)();
    }

    pub fn take_script(&self) -> Option<String> {
        let mut out = self.outbox.lock().unwrap_or_else(PoisonError::into_inner);
        self.pending.store(false, Ordering::Release);
        out.drain()
    }

    /// Flag a producer checks (and hands to `git::run`) to stop work for `req`.
    pub fn start(&self, req: u64) -> Arc<AtomicBool> {
        let flag = Arc::new(AtomicBool::new(false));
        self.cancels.lock().unwrap_or_else(PoisonError::into_inner).insert(req, flag.clone());
        flag
    }

    pub fn finish(&self, req: u64) {
        self.cancels.lock().unwrap_or_else(PoisonError::into_inner).remove(&req);
    }

    pub fn cancel(&self, req: u64) {
        if let Some(f) = self.cancels.lock().unwrap_or_else(PoisonError::into_inner).remove(&req) {
            f.store(true, Ordering::Relaxed);
        }
    }

    /// Window closed: stop every running request.
    pub fn cancel_all(&self) {
        for (_, f) in self.cancels.lock().unwrap_or_else(PoisonError::into_inner).drain() {
            f.store(true, Ordering::Relaxed);
        }
    }
}
