//! Does CoreAudio call us back? Opens the default output with an idle engine and counts callbacks.
use std::time::Duration;
fn main() {
    let want = std::env::var("DJ_AUDIO_DEVICE").ok();
    let out = djhost::audio::Output::open(want.as_deref(), None).unwrap();
    println!("device {} {} Hz", out.name, out.sample_rate());
    let cfg = djhost::deck::EngineConfig::new(out.sample_rate() as f64);
    let (_e, r) = djhost::deck::host_engine(cfg, true, true);
    let running = out.start(r, djhost::deck::output::Routing::Stereo, None).unwrap();
    for _ in 0..5 { std::thread::sleep(Duration::from_millis(400)); println!("beats {} ", running.health.beats()); }
}
