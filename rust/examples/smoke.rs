//! Host-side smoke test of the Player facade (no Swift): `cargo run --release --example smoke`.
use std::time::{Duration, Instant};
fn main() {
    let p = djmobile::Player::new(String::new()).expect("player");
    println!("{:?}", p.info());
    p.compose("A".into(), "house".into(), 42, None).unwrap();
    let t0 = Instant::now();
    while !p.state("A".into()).unwrap().loaded { std::thread::sleep(Duration::from_millis(20)); }
    println!("loaded after {:?}", t0.elapsed());
    p.set_playing("A".into(), true).unwrap();
    let mut peak = 0f32;
    for i in 0..30 {
        std::thread::sleep(Duration::from_millis(200));
        let s = p.state("A".into()).unwrap();
        peak = peak.max(s.level);
        if i % 5 == 0 { println!("playing={} tick={} tempo={:.1} level={:.3}", s.playing, s.tick, s.tempo, s.level); }
    }
    println!("peak {peak}");
}
