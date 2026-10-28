import AppKit
import SwiftUI

/// App-wide settings: audio processing options plus general preferences.
struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Settings").font(.title3.weight(.semibold))
                    Text("How SourceMix handles your audio").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore Defaults") { settings.restoreDefaults() }
                    .glassButtonStyle()
                    .disabled(settings.isDefault)
            }

            GlassGroup(spacing: 12) {
                VStack(spacing: 12) {
                    OptionCard(title: "Peak Limiter",
                               symbol: "waveform.path.ecg",
                               selection: $settings.limiter,
                               defaultValue: AppSettings.defaultLimiter,
                               defaultSummary: "Only rounds off peaks while you boost a source above 100%, so normal playback is untouched.",
                               detail: \.detail,
                               title: \.title)

                    OptionCard(title: "Clock Drift Correction",
                               symbol: "metronome",
                               selection: $settings.drift,
                               defaultValue: AppSettings.defaultDrift,
                               defaultSummary: "Off unless an app plays to a different device than your output. No resampling in the usual case.",
                               detail: \.detail,
                               title: \.title)

                    OptionCard(title: "Surround Audio",
                               symbol: "hifispeaker.2",
                               selection: $settings.surround,
                               defaultValue: AppSettings.defaultSurround,
                               defaultSummary: "Keeps every channel when your output has more than two; stereo outputs are unaffected.",
                               detail: \.detail,
                               title: \.title)

                    transparencyNote

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Launch at Login", isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .onChange(of: launchAtLogin) { _, on in
                                LoginItem.set(on)
                                launchAtLogin = LoginItem.isEnabled
                            }
                        Text("Starts SourceMix quietly in the menu bar when you log in. Default: off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassSurface(cornerRadius: 20)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .padding(.top, 34)
        .frame(width: 560)
        .fixedSize()
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }

    private var transparencyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("What SourceMix does to your audio").font(.headline)
                Text("SourceMix never resamples or reduces bit depth. It works in 32-bit float at your output's own sample rate. With the defaults above, a source at 100% with a flat EQ and Stereo channel is passed through bit-for-bit unchanged. macOS still converts each app's audio to your output's sample rate before SourceMix receives it, exactly as it would without SourceMix, and processing adds one audio buffer of delay (typically 5–10 ms).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20, tint: .green.opacity(0.12))
    }
}

/// A setting with a picker, its current behaviour, and what the default does.
private struct OptionCard<Option: Hashable & Identifiable & CaseIterable>: View where Option.AllCases: RandomAccessCollection {
    let title: String
    let symbol: String
    @Binding var selection: Option
    let defaultValue: Option
    let defaultSummary: String
    let detail: KeyPath<Option, String>
    let title_: KeyPath<Option, String>

    init(title: String, symbol: String, selection: Binding<Option>, defaultValue: Option,
         defaultSummary: String, detail: KeyPath<Option, String>, title optionTitle: KeyPath<Option, String>) {
        self.title = title
        self.symbol = symbol
        self._selection = selection
        self.defaultValue = defaultValue
        self.defaultSummary = defaultSummary
        self.detail = detail
        self.title_ = optionTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                Text(title).font(.headline)
                Spacer()
                Picker(title, selection: $selection) {
                    ForEach(Array(Option.allCases)) { option in
                        Text(option[keyPath: title_] + (option == defaultValue ? " (Default)" : ""))
                            .tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            Text(selection[keyPath: detail])
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if selection != defaultValue {
                Label {
                    Text("Default (\(defaultValue[keyPath: title_])): \(defaultSummary)")
                } icon: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This is the default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }
}
