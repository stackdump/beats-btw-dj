//! HEOS on the phone: djhost's HEOS service (djrust docs/HEOS.md, the desktop's), behind the
//! facade. Find the Denon zones (SSDP + mDNS), read and set each zone's volume, mute and
//! transport, group them, and have them play the phone's master mix, served from the phone as an
//! endless FLAC over HTTP (`djhost::heos::StreamServer`, the master's capture tap: nothing is
//! added to the audio callback).
//!
//! The zones play the stream a little behind the phone (HEOS buffers a URL stream before it
//! starts), but short enough to mix live by ear: tried on Kitchen.
//!
//! Its own lock, not the engine's: nothing here waits on the network while the decks need the
//! engine. The service starts the first time it is asked for ([`HeosSide::start`]).

use std::net::{IpAddr, SocketAddr};

use djhost::heos::discover::local_ip_toward;
use djhost::heos::stream::DEFAULT_PORT;
use djhost::heos::{Cmd, Format, Heos, PlayState, StreamServer, Target};

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HeosZone {
    pub pid: i64,
    pub name: String,
    pub model: String,
    pub ip: String,
    /// 0..100 (None until read).
    pub volume: Option<u8>,
    pub mute: Option<bool>,
    /// "play", "pause", "stop" (None until read).
    pub state: Option<String>,
    /// What it plays, in words ("djrust (the phone)" while it plays our stream).
    pub now: String,
    /// Its group, if any.
    pub gid: Option<i64>,
    /// The group's leader is this zone.
    pub leader: bool,
    /// Playing the phone's mix (it was sent our stream and has not been stopped).
    pub streaming: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HeosGroup {
    pub gid: i64,
    pub name: String,
    /// The leader first.
    pub members: Vec<i64>,
    pub volume: Option<u8>,
    pub mute: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HeosState {
    /// The service has been started.
    pub running: bool,
    pub connected: bool,
    /// In words: connecting, connected to …, why not.
    pub status: String,
    pub zones: Vec<HeosZone>,
    pub groups: Vec<HeosGroup>,
    /// The URL the zones fetch, while the stream server is up.
    pub stream_url: Option<String>,
    /// Zones fetching it now.
    pub listeners: u32,
    /// The last lines of the CLI log, newest last ("✗ " in front of a failure).
    pub log: Vec<String>,
    /// Bumped on every change the service sees.
    pub generation: u64,
}

impl HeosState {
    fn off() -> HeosState {
        HeosState {
            running: false,
            connected: false,
            status: "off".into(),
            zones: Vec::new(),
            groups: Vec::new(),
            stream_url: None,
            listeners: 0,
            log: Vec::new(),
            generation: 0,
        }
    }
}

pub struct HeosSide {
    heos: Heos,
    server: Option<StreamServer>,
    url: Option<String>,
    streaming: Vec<i64>,
}

impl HeosSide {
    /// Start the service: `host` (`host[:port]`) or None to find the players.
    pub fn start(host: Option<String>) -> HeosSide {
        let target = host.map_or(Target::Auto, |h| Target::parse(&h));
        HeosSide {
            heos: Heos::start(target),
            server: None,
            url: None,
            streaming: Vec::new(),
        }
    }

    pub fn send(&self, c: Cmd) {
        self.heos.send(c);
    }

    pub fn state(&self) -> HeosState {
        let s = self.heos.snapshot();
        let zones = s
            .players
            .iter()
            .map(|p| {
                let g = s.group_of(p.pid);
                // the desktop's rule: a zone we streamed to, on HEOS's URL source (sid 1024)
                let now = if p.now.sid == Some(1024) && self.streaming.contains(&p.pid) {
                    "djrust (the phone)".to_string()
                } else {
                    [p.now.song.as_str(), p.now.artist.as_str(), p.now.station.as_str()]
                        .iter()
                        .filter(|x| !x.is_empty())
                        .copied()
                        .collect::<Vec<_>>()
                        .join(" · ")
                };
                HeosZone {
                    pid: p.pid,
                    name: p.name.clone(),
                    model: p.model.clone(),
                    ip: p.ip.clone(),
                    volume: p.volume,
                    mute: p.mute,
                    state: p.state.map(|x| x.as_str().to_string()),
                    now,
                    gid: g.map(|g| g.gid),
                    leader: g.is_some_and(|g| g.leader() == p.pid),
                    streaming: self.streaming.contains(&p.pid),
                }
            })
            .collect();
        let groups = s
            .groups
            .iter()
            .map(|g| HeosGroup {
                gid: g.gid,
                name: g.name.clone(),
                members: g.members.iter().map(|m| m.0).collect(),
                volume: g.volume,
                mute: g.mute,
            })
            .collect();
        let log = s
            .log
            .iter()
            .rev()
            .take(8)
            .rev()
            .map(|l| if l.ok { l.text.clone() } else { format!("✗ {}", l.text) })
            .collect();
        HeosState {
            running: true,
            connected: s.connected,
            status: s.status.clone(),
            zones,
            groups,
            stream_url: self.server.as_ref().and(self.url.clone()),
            listeners: self.server.as_ref().map_or(0, |v| v.stats().listeners as u32),
            log,
            generation: s.generation,
        }
    }

    /// Play the phone's mix on `pids` (the first leads; several are grouped first, so HEOS
    /// keeps them together). `source` / `rate`: the engine's master tap, for the server.
    pub fn stream(
        &mut self,
        pids: &[i64],
        source: impl FnOnce() -> (std::sync::Arc<dyn djhost::heos::stream::PcmSource>, u32),
    ) -> Result<String, String> {
        let &leader = pids.first().ok_or("pick the zones to play on")?;
        let snap = self.heos.snapshot();
        let ip: IpAddr = snap
            .player(leader)
            .and_then(|p| p.ip.parse().ok())
            .ok_or("that zone's address isn't known yet (not connected?)")?;
        if self.server.is_none() {
            let (src, sr) = source();
            let bind = SocketAddr::from(([0, 0, 0, 0], DEFAULT_PORT));
            let srv = StreamServer::start(bind, src.clone(), sr)
                .or_else(|_| StreamServer::start(SocketAddr::from(([0, 0, 0, 0], 0)), src, sr))?;
            self.server = Some(srv);
        }
        let me = local_ip_toward(ip).ok_or("no route to that zone from the phone (on the same Wi-Fi?)")?;
        let url = self.server.as_ref().unwrap().url(me, Format::Flac);
        if pids.len() > 1 {
            let grouped = snap.group_of(leader).is_some_and(|g| {
                g.leader() == leader && pids.iter().all(|p| g.has(*p)) && g.members.len() == pids.len()
            });
            if !grouped {
                self.send(Cmd::SetGroup { pids: pids.to_vec() });
            }
        }
        self.send(Cmd::PlayUrl {
            pid: leader,
            url: url.clone(),
        });
        self.streaming = pids.to_vec();
        self.url = Some(url.clone());
        Ok(url)
    }

    /// Stop the zones playing the mix (a group once, from its leader) and close the server.
    pub fn stream_stop(&mut self) {
        let snap = self.heos.snapshot();
        let mut leaders: Vec<i64> = Vec::new();
        for p in &self.streaming {
            let l = snap.group_of(*p).map_or(*p, |g| g.leader());
            if !leaders.contains(&l) {
                leaders.push(l);
            }
        }
        for pid in leaders {
            self.send(Cmd::PlayState {
                pid,
                state: PlayState::Stop,
            });
        }
        self.streaming.clear();
        self.server = None;
        self.url = None;
    }

    /// Ungroup the group `pid` is in (from its leader).
    pub fn ungroup(&self, pid: i64) {
        let snap = self.heos.snapshot();
        if let Some(g) = snap.group_of(pid) {
            self.send(Cmd::SetGroup { pids: vec![g.leader()] });
        }
    }
}

pub fn off() -> HeosState {
    HeosState::off()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn off_says_so() {
        let s = off();
        assert!(!s.running && !s.connected && s.zones.is_empty());
    }
}
