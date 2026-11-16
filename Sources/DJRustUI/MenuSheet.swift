import DJRust
import SwiftUI

// The top bar and the menu sheet (djandroid ui/MenuSheet.kt, DESIGN §3, §4.1): one row, the
// same on every tab; everything that isn't played lives behind the menu icon. Opening, using or
// closing the sheet never touches playback.

enum MenuSection: String, CaseIterable, Identifiable {
  case share = "Share", output = "Output", heos = "HEOS speakers", identity = "Identity", charts = "Charts"
  case update = "Update", library = "Library", settings = "Settings", about = "About"
  var id: String { rawValue }
  /// The rows of the menu (HEOS is reached from Output).
  static var listed: [MenuSection] { allCases.filter { $0 != .heos } }
}

struct TopBar: View {
  let model: RustDJModel
  /// `DJ_MENU="HEOS speakers"` (a launch environment, for screenshots): open the menu there.
  @State private var start = ProcessInfo.processInfo.environment["DJ_MENU"].flatMap(MenuSection.init(rawValue:))
  @State private var open = ProcessInfo.processInfo.environment["DJ_MENU"] != nil

  var body: some View {
    HStack {
      Text("djrust").font(.system(size: 22, weight: .medium)).foregroundStyle(DJTheme.accent)
      Spacer()
      // status as small indicators beside the menu (DESIGN §3), each opening its section
      if model.heos.live {
        Button {
          start = .heos
          open = true
        } label: {
          Label("HEOS live", systemImage: "hifispeaker.2.fill").font(.system(size: 12))
            .foregroundStyle(DJTheme.accent).frame(minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      if let a = model.audio, !a.live {
        Button {
          start = .about
          open = true
        } label: {
          Label("output lost, reopening", systemImage: "speaker.slash.fill").font(.system(size: 12))
            .foregroundStyle(DJTheme.danger).frame(minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      Button {
        start = nil
        open = true
      } label: {
        Image(systemName: "line.3.horizontal").font(.system(size: 20)).foregroundStyle(DJTheme.dim)
          .frame(width: 48, height: 48).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Menu")
    }
    .frame(minHeight: 48)
    .sheet(isPresented: $open) {
      // a page-sized sheet: the HEOS zones and the cards have room on an iPad
      MenuSheet(model: model, section: start) { open = false }.presentationSizing(.page)
    }
  }
}

struct MenuSheet: View {
  let model: RustDJModel
  let onClose: () -> Void
  @State private var section: MenuSection?

  init(model: RustDJModel, section: MenuSection? = nil, onClose: @escaping () -> Void) {
    self.model = model
    self.onClose = onClose
    _section = State(initialValue: section)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        if section != nil {
          Button {
            section = section == .heos ? .output : nil
          } label: {
            Image(systemName: "chevron.left").frame(width: 44, height: 44)
          }
          .buttonStyle(.plain).accessibilityLabel("Back")
        }
        Text(section?.rawValue ?? "Menu").font(.system(size: 17, weight: .medium))
        Spacer()
        Button("Close", action: onClose).buttonStyle(.plain).foregroundStyle(DJTheme.accent)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          switch section {
          case nil:
            ForEach(MenuSection.listed) { s in row(s) }
          case .output: row(.heos)
          case .heos: HeosPage(model: model)
          case .library: library
          case .charts: charts
          case .update: update
          case .share, .identity: wallet
          case .settings: settings
          case .about: about
          }
        }
      }
    }
    .padding(16)
    .frame(minWidth: 360, minHeight: 420)
    .background(DJTheme.surface1)
    .preferredColorScheme(.dark)
    .tint(DJTheme.accent)
  }

  private func status(_ s: MenuSection) -> String {
    switch s {
    case .settings: model.screenOnCharging ? "on the charger: screen on" : model.keepScreenOnWhilePlaying ? "screen on while playing" : ""
    case .about: model.info.map { "\($0.sampleRate / 1000) kHz" } ?? ""
    case .output: model.heos.live ? "HEOS live" : "HEOS speakers"
    case .heos: model.heos.live ? "live" : "the Denon zones"
    case .library:
      model.info.map { i in
        let n = Int(i.soundFonts + i.localOnlyBanks)
        return "\(n) SoundFont\(n == 1 ? "" : "s")"
      } ?? ""
    case .charts: model.chartsOn ? "counting my plays" : "not counting my plays"
    case .update: "from Xcode"
    case .share, .identity: "needs the wallet"
    }
  }

  private func row(_ s: MenuSection) -> some View {
    Button {
      section = s
    } label: {
      HStack {
        Text(s.rawValue).font(.system(size: 14))
        Spacer()
        Text(status(s)).font(.system(size: 12))
          .foregroundStyle(s == .output && model.heos.live || s == .heos && model.heos.live ? DJTheme.accent : DJTheme.dim)
        Image(systemName: "chevron.right").foregroundStyle(DJTheme.dim)
      }
      .frame(minHeight: 48).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var settings: some View {
    @Bindable var m = model
    return VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Keep screen on while playing").font(.system(size: 14))
          Text("the screen stays awake while a deck plays").font(.system(size: 12)).foregroundStyle(DJTheme.dim)
        }
        Spacer()
        DJToggle(label: "Keep screen on while playing", isOn: $m.keepScreenOnWhilePlaying)
      }
      #if os(macOS)
        // the Mac's DJ controllers (DJRustMIDI): what is plugged in and driving the decks
        Text(
          model.controllers.isEmpty
            ? "Controllers: none plugged in (Inpulse 200 MK3, APC mini mk2, MPK mini mk2 are known)"
            : "Controllers: " + model.controllers.joined(separator: ", ")
        )
        .font(.system(size: 12)).foregroundStyle(DJTheme.dim)
      #endif
      #if os(iOS)
        // djandroid's rule, not a setting: plugged in, djrust is a deck display
        Text(
          model.screenOnCharging
            ? "On the charger now: the screen stays on while djrust is open."
            : "On the charger the screen stays on while djrust is open."
        )
        .font(.system(size: 12)).foregroundStyle(DJTheme.dim)
      #endif
    }
  }

  /// What the app has to play with: the SoundFonts (and, with the wallet, what was signed here).
  private var library: some View {
    let fonts = model.info.map { Int($0.soundFonts + $0.localOnlyBanks) }
    return VStack(alignment: .leading, spacing: 16) {
      Card("SoundFonts") {
        Text(
          fonts == nil ? "The engine is starting…" : fonts == 0 ? "None: the decks play synth voices." : "\(fonts!) loaded."
        )
        .font(.system(size: 14))
        #if os(iOS)
          Caption("Add .sf2 files in the Files app (On My iPad › beats-btw-dj › soundfonts), then restart the app:")
        #else
          Caption("Add .sf2 files to this folder, then restart djrust:")
        #endif
        Text(model.soundFontDir).font(.system(size: 11, design: .monospaced)).foregroundStyle(DJTheme.dim)
          .textSelection(.enabled)
      }
      Card("Saved on this iPad") {
        Caption(
          "Signed tracks and mixes are kept by the wallet (Share, Identity), which isn't on Apple yet: "
            + "nothing is saved here.")
      }
    }
  }

  /// "Count my plays toward the charts" (djandroid ChartsSection): off by default; nothing is sent
  /// in any build yet.
  private var charts: some View {
    @Bindable var m = model
    return Card("Track charts") {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Count my plays toward the charts").font(.system(size: 14))
          Text(model.chartsOn ? "On" : "Off").font(.system(size: 12))
            .foregroundStyle(model.chartsOn ? DJTheme.accent : DJTheme.dim)
        }
        Spacer()
        DJToggle(label: "Count my plays toward the charts", isOn: $m.chartsOn)
      }
      Caption(
        "The charts rank tracks by how many people played, saved and shared them each day. "
          + "They never show who listened, and nobody is ranked.")
      Caption(
        "When this is on, a track counts once you've heard it for 30 seconds, once a day. "
          + "djrust keeps no list of what you played.")
      Caption("Sending isn't built yet, so nothing is sent yet.")
    }
  }

  /// djandroid updates itself from the CDN; an iPad app can't.
  private var update: some View {
    let b = Bundle.main.infoDictionary
    return VStack(alignment: .leading, spacing: 8) {
      Text("This is beats-btw-dj \(b?["CFBundleShortVersionString"] as? String ?? "dev") (build \(b?["CFBundleVersion"] as? String ?? "dev")).")
        .font(.system(size: 14))
      Caption(
        "An iPad app can't update itself: a new build comes from Xcode on the Mac (docs/IPAD.md), "
          + "or from TestFlight once the app is there.")
    }
  }

  /// Share and Identity sign with the vevr-wallet (Android Keystore + BiometricPrompt there).
  private var wallet: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Not on the iPad yet").font(.system(size: 14))
      Caption(
        "Sharing a deck or the mix, and the identity that signs them, come from the vevr-wallet. Its Apple "
          + "side (Secure Enclave key, Face ID / Touch ID) isn't built yet; until then nothing here signs or shares.")
    }
  }

  private var about: some View {
    VStack(alignment: .leading, spacing: 6) {
      let bundle = Bundle.main.infoDictionary
      Text("beats-btw-dj on djrust \(bundle?["CFBundleShortVersionString"] as? String ?? "dev")")
      if let i = model.info {
        Text("\(i.sampleRate) Hz · \(i.soundFonts) SoundFonts (\(i.localOnlyBanks) local only)")
          .font(.system(size: 12, design: .monospaced)).foregroundStyle(DJTheme.dim)
      }
      if let a = model.audio {
        let state = a.live ? "live" : "lost, reopening"
        Text("output \(state) · \(a.losses) lost · \(a.restores) reopened" + (a.why.map { " · \($0)" } ?? ""))
          .font(.system(size: 12, design: .monospaced)).foregroundStyle(a.live ? DJTheme.dim : DJTheme.danger)
      }
      Text("SoundFonts: \(model.soundFontDir)").font(.system(size: 11, design: .monospaced))
        .foregroundStyle(DJTheme.dim).textSelection(.enabled)
    }
    .font(.system(size: 14))
  }
}
