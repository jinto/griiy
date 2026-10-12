use griiy::{args, config, events::Channel, git::Review, protocol};
use serde_json::{Value, json};
use std::{process::ExitCode, sync::Arc};
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
    let review = Review::open(&args.repo, &args.spec);
    let init = match &review {
        Ok(r) => json!({ "review": r.to_json() }),
        Err(e) => json!({ "error": e.to_json() }),
    };
    let review = Arc::new(review.ok());

    let event_loop = EventLoopBuilder::<Flush>::with_user_event().build();
    let proxy = event_loop.create_proxy();
    let channel = Channel::new(1_000, move || {
        let _ = proxy.send_event(Flush);
    });
    let window = WindowBuilder::new()
        .with_title("griiy")
        .with_inner_size(tao::dpi::LogicalSize::new(1100.0, 720.0))
        .build(&event_loop)?;
    let ipc = channel.clone();
    let webview = WebViewBuilder::new()
        .with_custom_protocol("griiy".into(), move |_, req| protocol::handle(req.uri(), (*review).as_ref()))
        .with_initialization_script(format!("window.__GRIIY__ = {init};"))
        .with_ipc_handler(move |req| {
            let msg: Value = serde_json::from_str(req.body()).unwrap_or_default();
            match msg["type"].as_str() {
                Some("ready") => ipc.ready(),
                Some("cancel") => msg["req"].as_u64().into_iter().for_each(|r| ipc.cancel(r)),
                // The page reports its timings after first paint; the bench reads this marker.
                Some("mark") => {
                    if let Ok(path) = std::env::var("GRIIY_MARK") {
                        let _ = std::fs::write(path, req.body());
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
