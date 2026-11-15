import DJRust
import SwiftUI

// The Denon HEOS zones (djandroid ui/HeosPage.kt; djrust docs/HEOS.md, as the desktop's HEOS
// window): find them (or type one's address), play the iPad's mix on the ticked ones, and each
// zone's volume, mute and transport. The zones hear the mix a little late (HEOS buffers a
// stream), but close enough to mix live by ear.

struct HeosPage: View {
  let model: RustDJModel

  var body: some View {
    let h = model.heos
    let s = h.state
    let zones = s?.zones ?? []
    let streaming = s?.streamUrl != nil
    VStack(spacing: 16) {
      Card(
        "HEOS",
        trailing: {
          Button(h.host.trimmingCharacters(in: .whitespaces).isEmpty ? "Find again" : "Connect") { model.heosConnect() }
            .buttonStyle(.plain).foregroundStyle(DJTheme.accent).frame(minHeight: 44)
        }
      ) {
        Text(h.finding ? "looking for zones (Bonjour)…" : (s?.status ?? "starting…")).font(.system(size: 14))
          .foregroundStyle(s?.connected == true ? Color.white : DJTheme.dim)
        if let problem = h.problem {
          Text(problem).font(.system(size: 13)).foregroundStyle(DJTheme.danger)
            .fixedSize(horizontal: false, vertical: true)
        }
        TextField("a zone's address (blank: find them)", text: Binding(get: { h.host }, set: { model.heosHost($0) }))
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()
          #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
          #endif
          .submitLabel(.go)
          .onSubmit { model.heosConnect() }
        #if os(iOS)
          // blank: found by Bonjour (the engine's multicast discovery needs Apple's entitlement)
          Caption("If no zones turn up, type one's address (Denon app › a speaker › About › IP address).")
        #endif
      }
      Card("Play the mix on the zones") {
        Caption(
          "Tick the zones, then Play. They lag the iPad a little (HEOS buffers a stream), close enough "
            + "to mix live by ear. Several zones are grouped so they stay together.")
        if zones.isEmpty {
          Text(s?.connected == true ? "no zones" : "looking for zones on this Wi-Fi…").foregroundStyle(DJTheme.dim)
        }
        ForEach(zones, id: \.pid) { z in
          let on = h.ticked.contains(z.pid)
          Button {
            model.heosTick(z.pid, !on)
          } label: {
            HStack {
              Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 20))
                .foregroundStyle(on ? DJTheme.accent : DJTheme.dim)
              Text(z.name).font(.system(size: 14)).foregroundStyle(.white)
              Spacer()
              if z.streaming { Text("playing the mix").font(.system(size: 12)).foregroundStyle(DJTheme.accent) }
            }
            .frame(minHeight: 44).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(z.name).accessibilityAddTraits(on ? .isSelected : [])
        }
        HStack(spacing: 8) {
          Button {
            model.heosStream()
          } label: {
            Label(streaming ? "Play on ticked" : "Play the mix", systemImage: "play.fill").font(.system(size: 14, weight: .medium))
              .foregroundStyle(Color.black).padding(.horizontal, 16).frame(minHeight: 44)
              .background(h.ticked.isEmpty ? DJTheme.dim : DJTheme.accent, in: RoundedRectangle(cornerRadius: 22))
          }
          .buttonStyle(.plain).disabled(h.ticked.isEmpty)
          Button {
            model.heosStreamStop()
          } label: {
            Label("Stop", systemImage: "stop.fill").font(.system(size: 14))
              .foregroundStyle(streaming ? Color.white : DJTheme.dim).padding(.horizontal, 16).frame(minHeight: 44)
              .overlay(RoundedRectangle(cornerRadius: 22).stroke(DJTheme.dim.opacity(0.6)))
          }
          .buttonStyle(.plain).disabled(!streaming)
        }
        // why Play or Stop is off (DESIGN §4.2.3)
        if h.ticked.isEmpty && !streaming {
          Caption("Tick a zone to play the mix on it")
        } else if h.ticked.isEmpty {
          Caption("Tick a zone to add it; Stop ends the stream")
        } else if !streaming {
          Caption("Nothing is streaming yet, so there is nothing to stop")
        }
        if streaming, let s {
          Text("\(s.listeners) zone\(s.listeners == 1 ? "" : "s") fetching \(s.streamUrl ?? "")")
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(DJTheme.dim).textSelection(.enabled)
          // the state only changes when the engine's does: tick so a stalled start gets said
          TimelineView(.periodic(from: .now, by: 2)) { t in
            if h.unfetched(now: t.date) {
              Text(
                "No zone has fetched the mix yet. The zones must reach this iPad at the address above: "
                  + "same Wi-Fi, no VPN on the iPad, and keep this app open. A zone that refused it says why in the Log."
              )
              .font(.system(size: 13)).foregroundStyle(DJTheme.danger).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        if h.ticked.count >= 2 {
          Button("Group the ticked zones") { model.heosGroupTicked() }.buttonStyle(.plain)
            .foregroundStyle(DJTheme.accent).frame(minHeight: 44)
        }
      }
      ForEach(zones, id: \.pid) { z in ZoneCard(model: model, zone: z) }
      ForEach(s?.groups ?? [], id: \.gid) { g in
        Card(
          "Group · \(g.name)",
          trailing: {
            Button("Ungroup") { if let m = g.members.first { model.heosUngroup(m) } }.buttonStyle(.plain)
              .foregroundStyle(DJTheme.accent).frame(minHeight: 44)
          }
        ) {
          VolumeRow(volume: g.volume.map(Int.init), muted: g.mute == true, onMute: nil) { model.heosGroupVolume(g.gid, $0) }
        }
      }
      if let log = s?.log, !log.isEmpty {
        Card("Log") {
          ForEach(Array(log.enumerated()), id: \.offset) { _, l in
            Text(l).font(.system(size: 11, design: .monospaced))
              .foregroundStyle(l.hasPrefix("✗") ? DJTheme.danger : DJTheme.dim).textSelection(.enabled)
          }
        }
      }
    }
    .task { model.heosStart() }
  }
}

private struct ZoneCard: View {
  let model: RustDJModel
  let zone: HeosZone

  var body: some View {
    let z = zone
    let group = model.heos.state?.groups.first { $0.gid == z.gid }
    let playing = z.state == "play"
    Card(z.name, trailing: { Caption(z.model).font(.system(size: 11)) }) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(z.now.isEmpty ? "nothing" : z.now).font(.system(size: 14)).lineLimit(1)
            .foregroundStyle(z.streaming && z.now.hasPrefix("djrust") ? DJTheme.accent : Color.white)
          Text(
            [z.state, group.map { "in \($0.name)" + (z.leader ? " (leads)" : "") }, z.ip].compactMap { $0 }
              .joined(separator: " · ")
          )
          .font(.system(size: 11, design: .monospaced)).foregroundStyle(DJTheme.dim)
        }
        Spacer()
        Button {
          model.heosTransport(z.pid, playing ? "pause" : "play")
        } label: {
          Image(systemName: playing ? "pause.fill" : "play.fill").foregroundStyle(DJTheme.accent)
            .frame(width: 48, height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(playing ? "Pause \(z.name)" : "Play \(z.name)")
        Button {
          model.heosTransport(z.pid, "stop")
        } label: {
          Image(systemName: "stop.fill").foregroundStyle(DJTheme.dim).frame(width: 48, height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Stop \(z.name)")
      }
      VolumeRow(volume: z.volume.map(Int.init), muted: z.mute == true, onMute: { model.heosMute(z.pid) }) {
        model.heosVolume(z.pid, $0)
      }
    }
  }
}

/// A HEOS volume 0…100 and its mute; the slider sends while it moves (the service coalesces).
private struct VolumeRow: View {
  let volume: Int?
  let muted: Bool
  let onMute: (() -> Void)?
  let onChange: (Int) -> Void
  @State private var dragging = false
  @State private var local = 0.0

  var body: some View {
    HStack {
      if let onMute {
        Button(action: onMute) {
          Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            .foregroundStyle(muted ? DJTheme.danger : DJTheme.dim).frame(width: 48, height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(muted ? "Unmute" : "Mute")
      }
      if let volume {
        Slider(
          value: Binding(
            get: { dragging ? local : Double(volume) / 100 },
            set: {
              dragging = true
              local = $0
              onChange(Int(($0 * 100).rounded()))
            }), in: 0...1, onEditingChanged: { if !$0 { dragging = false } }
        )
        .accessibilityLabel("Volume").accessibilityValue("\(volume)")
        Text("\(volume)").font(.system(size: 12, design: .monospaced)).foregroundStyle(DJTheme.dim).frame(width: 32)
      } else {
        // the zone hasn't said its volume yet: say so rather than show a dead slider
        Caption("reading the volume…")
        Spacer()
      }
    }
  }
}
