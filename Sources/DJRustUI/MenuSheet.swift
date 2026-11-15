import DJRust
import SwiftUI

// The top bar and the menu sheet (djandroid ui/MenuSheet.kt, DESIGN §3, §4.1): one row, the
// same on every tab; everything that isn't played lives behind the menu icon. Opening, using or
// closing the sheet never touches playback.

enum MenuSection: String, CaseIterable, Identifiable {
  case share = "Share", output = "Output", identity = "Identity", charts = "Charts", update = "Update"
  case library = "Library", settings = "Settings", about = "About"
  var id: String { rawValue }
}

struct TopBar: View {
  let model: RustDJModel
  @State private var open = false
  @State private var start: MenuSection?

  var body: some View {
    HStack {
      Text("djrust").font(.system(size: 22, weight: .medium)).foregroundStyle(DJTheme.accent)
      Spacer()
      // status as a small indicator beside the menu (DESIGN §3): the output stream lost
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
    .sheet(isPresented: $open) { MenuSheet(model: model, section: start) { open = false } }
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
            section = nil
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
            ForEach(MenuSection.allCases) { s in row(s) }
          case .settings: settings
          case .about: about
          case let s?: Text("\(s.rawValue): not ported yet (docs/ANDROID-PORT.md)").foregroundStyle(DJTheme.dim)
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
    default: "not yet"
    }
  }

  private func row(_ s: MenuSection) -> some View {
    Button {
      section = s
    } label: {
      HStack {
        Text(s.rawValue).font(.system(size: 14))
        Spacer()
        Text(status(s)).font(.system(size: 12)).foregroundStyle(DJTheme.dim)
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
      Text("SoundFonts: \(RustEngine.defaultSoundFontDir)").font(.system(size: 11, design: .monospaced))
        .foregroundStyle(DJTheme.dim).textSelection(.enabled)
    }
    .font(.system(size: 14))
  }
}
