import AppKit
import SwiftUI

extension VideoEditorTheme {
    static let caption = Color(red: 0.2, green: 0.74, blue: 0.68)
    static let keys = Color(red: 0.55, green: 0.62, blue: 0.78)
    static let camera = Color(red: 0.3, green: 0.62, blue: 1.0)
}

// MARK: - Script

/// Your words: edit the video by editing them, and turn them into captions.
struct VideoScriptInspector: View {
    @ObservedObject var model: VideoEditorModel
    @AppStorage("videoScriptMode") private var mode = "transcript"

    var body: some View {
        if model.project.captions.isEmpty || model.captionJob != nil {
            ScrollView {
                VideoCaptionsInspector(model: model)
                    .padding(16)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VideoSegmented(options: [("transcript", "Edit by text"), ("captions", "Captions")], selection: $mode)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                if mode == "transcript" {
                    VideoTranscriptPanel(model: model, timeline: model.timelineState)
                } else {
                    ScrollView {
                        VideoCaptionsInspector(model: model)
                            .padding(16)
                    }
                }
            }
        }
    }
}

/// Cleanup buttons over the editable transcript.
struct VideoTranscriptPanel: View {
    let model: VideoEditorModel
    /// Counts refresh only when the timeline changes, not on every edit.
    @ObservedObject var timeline: VideoTimelineState

    var body: some View {
        let fillers = model.fillerCount
        let pauses = model.pauseRanges
        let pauseSeconds = pauses.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                cleanup(
                    title: fillers > 0 ? "Remove \(fillers) um\(fillers == 1 ? "" : "s")" : "No ums",
                    symbol: "wand.and.stars",
                    help: "Cut filler words like um and uh",
                    enabled: fillers > 0,
                    action: model.removeFillers
                )
                cleanup(
                    title: pauses.isEmpty ? "No long pauses" : "Shorten \(pauses.count) pause\(pauses.count == 1 ? "" : "s")",
                    symbol: "forward.end",
                    help: pauses.isEmpty
                        ? "Silences over a second where nothing happens on screen get shortened"
                        : "Saves \(VideoEditorModel.format(pauseSeconds)) — only silences where nothing happens on screen",
                    enabled: !pauses.isEmpty,
                    action: model.shortenPauses
                )
            }
            Text("Select words and press ⌫ to cut them from the video — ⌫ again on crossed-out words puts them back. Click a word to jump there; ⌘F finds.")
                .font(.system(size: 10.5))
                .foregroundStyle(VideoEditorTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            VideoTranscriptEditor(model: model, timeline: timeline, clock: model.clock)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.22)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(VideoEditorTheme.cardStroke, lineWidth: 1))
        }
        .padding(16)
    }

    private func cleanup(title: String, symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(VideoSecondaryButtonStyle())
        .disabled(!enabled)
        .help(help)
    }
}

// MARK: - Captions

struct VideoCaptionsInspector: View {
    @ObservedObject var model: VideoEditorModel

    private var style: VideoCaptionStyle { model.project.captionStyle }

    private func binding<T>(_ keyPath: WritableKeyPath<VideoCaptionStyle, T>) -> Binding<T> {
        Binding(get: { model.project.captionStyle[keyPath: keyPath] }, set: { value in model.setStyle { $0.captionStyle[keyPath: keyPath] = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.project.captions.isEmpty || model.captionJob != nil {
                generateCard
            }
            if !model.project.captions.isEmpty {
                VideoInspectorSection("Look") {
                    VideoToggleRow(title: "Show captions", isOn: binding(\.visible))
                    VideoToggleRow(title: "Highlight words", detail: "Words light up as they're spoken", isOn: binding(\.highlightWords))
                    labeled("Size") {
                        VideoSegmented(options: VideoTextSize.allCases.map { ($0, $0.title) }, selection: binding(\.size))
                    }
                    labeled("Position") {
                        VideoSegmented(options: VideoTextPosition.allCases.map { ($0, $0.title) }, selection: binding(\.position))
                    }
                }
                .disabled(model.captionJob != nil)

                VideoInspectorSection("Lines · \(model.project.captions.count)", trailing: {
                    Button {
                        model.addCaptionAtPlayhead()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 22, height: 20)
                    }
                    .buttonStyle(VideoToolButtonStyle())
                    .help("Add a caption at the playhead")
                }) {
                    VideoCaptionLinesList(model: model, clock: model.clock)
                }

                HStack(spacing: 8) {
                    Button {
                        model.exportSRT()
                    } label: {
                        Label("Save .srt", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(VideoSecondaryButtonStyle())
                    .help("Subtitles file for YouTube and other players — follows your cuts")
                    Menu {
                        Button("Transcribe Again") { model.generateCaptions() }
                        Divider()
                        Button("Remove All Captions", role: .destructive) { model.clearCaptions() }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 30, height: 26)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
                }
            }
        }
        .onAppear { model.loadCaptionLanguages() }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VideoEditorTheme.textPrimary)
                .frame(width: 58, alignment: .leading)
            content()
        }
    }

    @ViewBuilder
    private var generateCard: some View {
        VideoCard {
            Label("Your words, as text", systemImage: "text.quote")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VideoEditorTheme.textPrimary)
            Text(model.hasAudio
                 ? "Shotnix listens to the recording right on this Mac — nothing is uploaded. Then cut the video by deleting words, remove ums and long pauses in one click, and add captions."
                 : "This recording has no sound. Turn on the microphone before recording to narrate it.")
                .font(.system(size: 11))
                .foregroundStyle(VideoEditorTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let job = model.captionJob {
                if let error = job.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.captionJob = nil
                        model.generateCaptions()
                    } label: {
                        Text("Try Again").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(VideoPrimaryButtonStyle())
                    .disabled(!model.hasAudio)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(job.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(VideoEditorTheme.textPrimary)
                            Spacer()
                            if let fraction = job.fraction {
                                Text("\(Int((fraction * 100).rounded()))%")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(VideoEditorTheme.textSecondary)
                            }
                        }
                        if let fraction = job.fraction {
                            ProgressView(value: fraction).progressViewStyle(.linear).tint(VideoEditorTheme.caption)
                        } else {
                            ProgressView().progressViewStyle(.linear).tint(VideoEditorTheme.caption)
                        }
                        Button("Cancel") { model.cancelCaptions() }
                            .buttonStyle(VideoSecondaryButtonStyle())
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Text("Language")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                    Spacer()
                    Menu {
                        Button("\(VideoEditorModel.systemLanguageTitle) (This Mac)") {
                            model.captionLanguage = ""
                        }
                        if !model.captionLanguages.isEmpty {
                            Divider()
                            ForEach(model.captionLanguages) { language in
                                Button(language.title) { model.captionLanguage = language.identifier }
                            }
                        }
                    } label: {
                        Text(model.captionLanguageTitle)
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button {
                    model.generateCaptions()
                } label: {
                    Label("Transcribe", systemImage: "waveform.badge.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoPrimaryButtonStyle())
                .disabled(!model.hasAudio)
                Button {
                    model.addCaptionAtPlayhead()
                } label: {
                    Text("Or type one at the playhead")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Editable caption lines; the one under the playhead is highlighted.
struct VideoCaptionLinesList: View {
    @ObservedObject var model: VideoEditorModel
    @ObservedObject var clock: VideoDemoPlaybackClock

    var body: some View {
        let current = model.plan.caption(at: clock.time)?.id
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(model.project.captions) { line in
                VideoCaptionRow(model: model, line: line, isCurrent: current == line.id, isSelected: model.selectedCaptionID == line.id)
            }
        }
    }
}

private struct VideoCaptionRow: View {
    @ObservedObject var model: VideoEditorModel
    let line: VideoCaptionLine
    let isCurrent: Bool
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                model.selectCaption(line.id)
            } label: {
                Text(VideoEditorModel.timecode(model.timelineTime(forSource: line.start) ?? line.start))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isCurrent ? VideoEditorTheme.caption : VideoEditorTheme.textTertiary)
                    .frame(width: 44, alignment: .leading)
                    .padding(.top, 3)
            }
            .buttonStyle(.plain)
            .help("Jump here")
            TextField("Caption", text: Binding(get: { line.text }, set: { model.updateCaption(line.id, text: $0) }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(VideoEditorTheme.textPrimary)
                .lineLimit(1...4)
                .onSubmit { model.endGesture() }
            if hovering {
                Button {
                    model.deleteCaption(line.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(VideoEditorTheme.textTertiary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Remove this caption")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? VideoEditorTheme.caption.opacity(0.18) : (isCurrent ? Color.white.opacity(0.07) : (hovering ? Color.white.opacity(0.04) : Color.clear)))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Keyboard shortcuts

struct VideoKeyboardSection: View {
    @ObservedObject var model: VideoEditorModel

    private func binding<T>(_ keyPath: WritableKeyPath<VideoKeystrokeStyle, T>) -> Binding<T> {
        Binding(get: { model.project.keystrokeStyle[keyPath: keyPath] }, set: { value in model.setStyle { $0.keystrokeStyle[keyPath: keyPath] = value } })
    }

    var body: some View {
        VideoInspectorSection("Keyboard shortcuts") {
            if model.project.keystrokes.isEmpty {
                Text("None in this recording. Turn on “Show keyboard shortcuts” in Settings → Recording and every ⌘ shortcut you press appears as keycaps. Plain typing is never recorded.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Recording Settings…") {
                    PreferencesWindowController.shared.show(tab: .recording)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
            } else {
                VideoToggleRow(
                    title: "Show shortcuts",
                    detail: "\(model.project.keystrokes.count) pressed — select one on the timeline and press ⌫ to hide it",
                    isOn: binding(\.visible)
                )
                HStack(spacing: 10) {
                    Text("Size")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VideoEditorTheme.textPrimary)
                        .frame(width: 58, alignment: .leading)
                    VideoSegmented(options: VideoTextSize.allCases.map { ($0, $0.title) }, selection: binding(\.size))
                }
                .disabled(!model.project.keystrokeStyle.visible)
                HStack(spacing: 10) {
                    Text("Position")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VideoEditorTheme.textPrimary)
                        .frame(width: 58, alignment: .leading)
                    VideoSegmented(options: VideoTextPosition.allCases.map { ($0, $0.title) }, selection: binding(\.position))
                }
                .disabled(!model.project.keystrokeStyle.visible)
            }
        }
    }
}

// MARK: - Camera

struct VideoCameraInspector: View {
    @ObservedObject var model: VideoEditorModel

    private func binding<T>(_ keyPath: WritableKeyPath<VideoWebcamSettings, T>, coalesce: String? = nil) -> Binding<T> {
        Binding(get: { model.project.webcam[keyPath: keyPath] }, set: { value in model.setStyle(coalesce: coalesce) { $0.webcam[keyPath: keyPath] = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.webcamRecording == nil {
                VideoCard {
                    Label("No camera in this recording", systemImage: "video.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VideoEditorTheme.textPrimary)
                    Text("Turn on the camera in the recording bar before you record, and your face appears here as a bubble you can place, resize, and restyle.")
                        .font(.system(size: 11))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VideoInspectorSection("Camera") {
                    VideoToggleRow(title: "Show camera", isOn: binding(\.visible))
                    VideoSegmented(options: VideoWebcamSettings.Shape.allCases.map { ($0, $0.title) }, selection: binding(\.shape))
                    VideoSliderRow(
                        title: "Size",
                        value: binding(\.size, coalesce: "webcam-size"),
                        range: VideoWebcamSettings.sizeRange,
                        defaultValue: VideoWebcamSettings().size,
                        format: { "\(Int(($0 * 100).rounded()))%" },
                        onEditingEnded: { model.endGesture() }
                    )
                }
                .disabled(false)

                VideoInspectorSection("Position") {
                    VideoAnchorPicker(selection: binding(\.anchor))
                    Text("Or drag the bubble on the video — it snaps to the nearest spot.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(VideoEditorTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(!model.project.webcam.visible)

                VideoInspectorSection("Behavior") {
                    VideoToggleRow(title: "Mirror", detail: "Flip like a selfie", isOn: binding(\.mirror))
                    VideoToggleRow(title: "Shrink while zoomed", detail: "Gets out of the way during zoom moves", isOn: binding(\.shrinkWhenZoomed))
                }
                .disabled(!model.project.webcam.visible)
            }
        }
    }
}

/// Eight spots around a mini frame.
struct VideoAnchorPicker: View {
    @Binding var selection: VideoWebcamSettings.Anchor

    var body: some View {
        let size = CGSize(width: 150, height: 88)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.3))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(VideoEditorTheme.cardStroke, lineWidth: 1))
                .frame(width: size.width, height: size.height)
            ForEach(VideoWebcamSettings.Anchor.allCases) { anchor in
                let selected = anchor == selection
                let inset: CGFloat = 16
                let point = CGPoint(
                    x: inset + (size.width - inset * 2) * anchor.unit.x,
                    y: inset + (size.height - inset * 2) * anchor.unit.y
                )
                Button {
                    selection = anchor
                } label: {
                    Circle()
                        .fill(selected ? VideoEditorTheme.camera : Color.white.opacity(0.22))
                        .frame(width: selected ? 16 : 10, height: selected ? 16 : 10)
                        .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(point)
                .help(anchor.rawValue)
            }
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: selection)
    }
}
