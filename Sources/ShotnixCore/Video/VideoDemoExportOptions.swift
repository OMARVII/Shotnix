import AppKit
import SwiftUI

/// User-facing export choices, shown as the save panel's accessory view and
/// persisted across exports.
struct VideoDemoExportOptions: Equatable {
    enum Format: String, CaseIterable, Identifiable {
        case mp4
        case gif

        var id: String { rawValue }
        var title: String {
            switch self {
            case .mp4: return "MP4"
            case .gif: return "GIF"
            }
        }
    }

    var format: Format = .mp4
    var fps: Int = 30
    var halfResolution = false
    var endCard = true

    static var fromSettings: VideoDemoExportOptions {
        VideoDemoExportOptions(
            format: Format(rawValue: Settings.videoExportFormat) ?? .mp4,
            fps: Settings.videoExportFPS,
            halfResolution: Settings.videoExportHalfResolution,
            endCard: Settings.videoExportEndCard
        )
    }

    func saveAsDefaults() {
        Settings.videoExportFormat = format.rawValue
        Settings.videoExportFPS = fps
        Settings.videoExportHalfResolution = halfResolution
        Settings.videoExportEndCard = endCard
    }

    var fileExtension: String { format == .gif ? "gif" : "mp4" }
}

@MainActor
final class VideoDemoExportOptionsModel: ObservableObject {
    @Published var options: VideoDemoExportOptions {
        didSet {
            if oldValue.format != options.format {
                onFormatChange?(options.format)
            }
        }
    }

    /// Lets the save panel swap its allowed content type + filename extension
    /// live when the user flips the format picker.
    var onFormatChange: ((VideoDemoExportOptions.Format) -> Void)?

    init(options: VideoDemoExportOptions) {
        self.options = options
    }
}

/// Compact accessory row inside the export save panel: format, frame rate,
/// size, and the end-card toggle.
struct VideoDemoExportAccessoryView: View {
    @ObservedObject var model: VideoDemoExportOptionsModel

    var body: some View {
        HStack(spacing: 18) {
            Picker("Format:", selection: $model.options.format) {
                ForEach(VideoDemoExportOptions.Format.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)

            Picker("Frame rate:", selection: $model.options.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            .frame(width: 140)
            .disabled(model.options.format == .gif)
            .help(model.options.format == .gif ? "GIFs export at 15 fps" : "Output frame rate")

            Picker("Size:", selection: $model.options.halfResolution) {
                Text("Full").tag(false)
                Text("Half").tag(true)
            }
            .frame(width: 110)

            Toggle("End card", isOn: $model.options.endCard)
                .help("Adds a short \"Made with Shotnix\" outro (MP4 only)")
                .disabled(model.options.format == .gif)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
