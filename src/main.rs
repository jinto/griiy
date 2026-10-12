use griiy::{
    args, config,
    events::Channel,
    git::{Error, Review},
    protocol,
};
use serde_json::{Value, json};
use std::{
    process::ExitCode,
    sync::{Arc, OnceLock},
};
use tao::{
    event::{Event, WindowEvent},
    event_loop::{ControlFlow, EventLoopBuilder},
    window::WindowBuilder,
};
use wry::WebViewBuilder;

/// Wakes the event loop to deliver queued channel messages.
struct Flush;

fn main() -> ExitCode {
    // Usage errors go to the terminal; everything after this shows in the window (F-IN-5).
    let args = match args::parse(std::env::args_os().skip(1)) {
        Ok(a) => a,
        Err(usage) => {
            eprintln!("{usage}");
            return ExitCode::from(2);
        }
    };
    match run(args) {
        Ok(()) => ExitCode::SUCCESS,
        // Only failures that can't be shown in a window end up here.
        Err(e) => {
            eprintln!("griiy: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: args::Args) -> Result<(), Box<dyn std::error::Error>> {
    for w in griiy::app_dir().map(|d| config::load(&d.join("config.toml")).1).unwrap_or_default() {
        eprintln!("griiy: config: {w}");
    }
    // Under bench.sh the page also auto-scrolls and reports frame times.
    let init = json!({ "bench": std::env::var_os("GRIIY_MARK").is_some() });
    let review: Arc<OnceLock<Review>> = Arc::default();
    // What request 0 delivered, kept so a reloaded page (a restarted WebContent process) gets it too.
    let delivered: Arc<OnceLock<(&str, Value)>> = Arc::default();

    let event_loop = EventLoopBuilder::<Flush>::with_user_event().build();
    let proxy = event_loop.create_proxy();
    let channel = Channel::new(1_000, move || {
        let _ = proxy.send_event(Flush);
    });
    let window = WindowBuilder::new()
        .with_title("griiy")
        .with_inner_size(tao::dpi::LogicalSize::new(1100.0, 720.0))
        .build(&event_loop)?;
    // git runs while the window and WebKit start. The review reaches the page on the event channel
    // (a custom-protocol fetch costs ~150ms at startup; a queued evaluate_script doesn't).
    let (opened, out, sent) = (review.clone(), channel.clone(), delivered.clone());
    std::thread::spawn(move || {
        let result = std::panic::catch_unwind(|| Review::open(&args.repo, &args.spec))
            .unwrap_or_else(|_| Err(Error::Git { detail: "opening the review panicked".into() }));
        let msg = match result {
            // Stored before it's announced, so the page's first api/diff finds it.
            Ok(r) => {
                let v = r.to_json();
                let _ = opened.set(r);
                ("review", v)
            }
            Err(e) => ("error", e.to_json()),
        };
        out.send(0, msg.0, msg.1.clone());
        let _ = sent.set(msg);
    });
    // ponytail: closing the window doesn't kill a git still computing the diff; it dies on its next
    // write to the closed pipe. Pass a cancel flag into Review::open if a huge repo shows otherwise.
    let served = review;
    let ipc = channel.clone();
    let webview = WebViewBuilder::new()
        .with_custom_protocol("griiy".into(), move |_, req| protocol::handle(req.uri(), served.get()))
        .with_initialization_script(format!("window.__GRIIY__ = {init};"))
        .with_ipc_handler(move |req| {
            let msg: Value = serde_json::from_str(req.body()).unwrap_or_default();
            match msg["type"].as_str() {
                Some("ready") => {
                    ipc.ready();
                    // A second copy on first load is harmless: the page takes the first.
                    if let Some((kind, data)) = delivered.get() {
                        ipc.send(0, kind, data.clone());
                    }
                }
                Some("cancel") => msg["req"].as_u64().into_iter().for_each(|r| ipc.cancel(r)),
                // The page reports timings after first paint, then after auto-scroll: one JSON line each.
                Some("mark") => {
                    if let Ok(path) = std::env::var("GRIIY_MARK") {
                        let file = std::fs::OpenOptions::new().create(true).append(true).open(path);
                        let _ = file.and_then(|mut f| {
                            std::io::Write::write_all(&mut f, format!("{}\n", req.body()).as_bytes())
                        });
                    }
                }
                _ => {}
            }
        })
        // Never leave the app: a dropped file or a stray link would otherwise get __GRIIY__ and window.ipc.
        .with_navigation_handler(|url| url.starts_with("griiy://app/"))
        .with_drag_drop_handler(|_| true)
        .with_url("griiy://app/index.html")
        .build(&window)?;

    event_loop.run(move |event, _, flow| {
        *flow = ControlFlow::Wait;
        match event {
            Event::UserEvent(Flush) => {
                if let Some(js) = channel.take_script() {
                    let _ = webview.evaluate_script(&js);
                }
            }
            Event::WindowEvent { event: WindowEvent::CloseRequested, .. } => {
                channel.cancel_all();
                *flow = ControlFlow::Exit;
            }
            _ => {}
        }
    });
}
