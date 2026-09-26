import AppKit
import SwiftUI

/// Background swatch thumbnails, rendered once.
@MainActor
final class VideoSwatchCache: ObservableObject {
    static let shared = VideoSwatchCache()

    @Published private(set) var pictures: [String: NSImage] = [:]
    private var images: [VideoBackground: NSImage] = [:]
    private var loading: Set<String> = []
    lazy var systemWallpapers: [URL] = VideoBackgroundCatalog.systemWallpapers()

    func image(for background: VideoBackground) -> NSImage? {
        if let cached = images[background] { return cached }
        switch background {
        case .wallpaper, .gradient, .color:
            let size = CGSize(width: 176, height: 110)
            let image = VideoBackgroundRenderer.image(for: background, blur: 0, size: size)
            guard let cgImage = VideoRenderContext.shared.createCGImage(image, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
            let result = NSImage(cgImage: cgImage, size: NSSize(width: size.width / 2, height: size.height / 2))
            images[background] = result
            return result
        case .image(let path), .systemWallpaper(let path):
            if let picture = pictures[path] { return picture }
            loadPicture(path)
            return nil
        }
    }

    private func loadPicture(_ path: String) {
        guard !loading.contains(path) else { return }
        loading.insert(path)
        Task.detached(priority: .utility) {
            let thumbnail = VideoBackgroundRenderer.thumbnail(path: path, maxPixel: 240)
            await MainActor.run {
                if let thumbnail { self.pictures[path] = thumbnail }
            }
        }
    }
}

struct VideoInspectorView: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                tabBar
                Rectangle().fill(VideoEditorTheme.hairline).frame(height: 1)
                // The selected object's settings sit above the tab, which
                // stays where it was (its list keeps its scroll position).
                if model.selection != .none {
                    // The tab keeps room to work in — the transcript most.
                    let keep: CGFloat = model.inspectorTab == .captions ? 330 : 220
                    VideoSelectionInspector(model: model, maxHeight: max(min(proxy.size.height * 0.6, proxy.size.height - 58 - keep), 170))
                    Rectangle().fill(VideoEditorTheme.hairline).frame(height: 1)
                }
                tabContent
            }
        }
        .background(VideoEditorTheme.panel)
    }

    @ViewBuilder
    private var tabContent: some View {
        if model.inspectorTab == .captions {
            // The transcript scrolls itself, so this tab fills the height.
            VideoScriptInspector(model: model)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch model.inspectorTab {
                    case .background: VideoBackgroundInspector(model: model)
                    case .cursor: VideoCursorInspector(model: model)
                    case .zoom: VideoZoomInspector(model: model)
                    case .camera: VideoCameraInspector(model: model)
                    case .captions: VideoCaptionsInspector(model: model)
                    case .audio: VideoAudioInspector(model: model)
                    }
                }
                .padding(16)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(VideoEditorModel.InspectorTab.allCases) { tab in
                let selected = model.inspectorTab == tab
                Button {
                    model.inspectorTab = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(height: 17)
                        Text(tab.title)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(selected ? VideoEditorTheme.textPrimary : VideoEditorTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? Color.white.opacity(0.09) : Color.clear)
                    )
                    .overlay(alignment: .topTrailing) {
                        // A narrated video nobody transcribed yet.
                        if tab == .captions, model.suggestsTranscript {
                            Circle()
                                .fill(VideoEditorTheme.caption)
                                .frame(width: 7, height: 7)
                                .padding(.top, 7)
                                .padding(.trailing, 9)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab == .captions && model.suggestsTranscript ? "Your narration can become captions — transcribe it here" : tab.help)
                .accessibilityLabel(tab.title)
                .accessibilityHint(tab.help)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector tabs")
    }
}

// MARK: - Background

struct VideoBackgroundInspector: View {
    @ObservedObject var model: VideoEditorModel
    @ObservedObject private var swatches = VideoSwatchCache.shared
    @State private var kind: Kind = .wallpaper

    enum Kind: Hashable {
        case wallpaper, gradient, color, image
    }

    private var project: VideoDemoProject { model.project }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VideoInspectorSection("Background", trailing: {
                Button {
                    model.shuffleBackground()
                } label: {
                    Image(systemName: "dice")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Shuffle the background")
                .accessibilityLabel("Shuffle the background")
            }) {
                VideoSegmented(options: [(.wallpaper, "Wallpaper"), (.gradient, "Gradient"), (.color, "Color"), (.image, "Image")], selection: $kind)
                swatchGrid
                if showsBlur {
                    VideoSliderRow(
                        title: "Blur",
                        value: Binding(get: { project.backgroundBlur }, set: { value in model.setStyle(coalesce: "bg-blur") { $0.backgroundBlur = value } }),
                        range: 0...1,
                        defaultValue: 0,
                        format: { "\(Int(($0 * 100).rounded()))%" },
                        onEditingEnded: { model.endGesture() }
                    )
                }
            }

            VideoInspectorSection("Frame") {
                VideoSliderRow(
                    title: "Padding",
                    value: Binding(get: { project.padding }, set: { value in model.setStyle(coalesce: "padding") { $0.padding = value } }),
                    range: 0...0.25,
                    defaultValue: VideoStylePreset.factory.padding,
                    format: { "\(Int(($0 * 400).rounded()))" },
                    onEditingEnded: { model.endGesture() }
                )
                VideoSliderRow(
                    title: "Roundness",
                    value: Binding(get: { project.cornerRadius }, set: { value in model.setStyle(coalesce: "radius") { $0.cornerRadius = value } }),
                    range: 0...60,
                    defaultValue: VideoStylePreset.factory.cornerRadius,
                    format: { "\(Int($0.rounded()))" },
                    onEditingEnded: { model.endGesture() }
                )
                VideoSliderRow(
                    title: "Shadow",
                    value: Binding(get: { project.shadow }, set: { value in model.setStyle(coalesce: "shadow") { $0.shadow = value } }),
                    range: 0...1,
                    defaultValue: VideoStylePreset.factory.shadow,
                    format: { "\(Int(($0 * 100).rounded()))%" },
                    onEditingEnded: { model.endGesture() }
                )
                VideoToggleRow(
                    title: "Edge highlight",
                    detail: "A hairline that separates dark recordings from the background",
                    isOn: Binding(get: { project.outline }, set: { value in model.setStyle { $0.outline = value } })
                )
                Button {
                    model.setStyle { project in
                        project.padding = project.usesRawSourceFrame ? VideoStylePreset.factory.padding : 0
                    }
                } label: {
                    Label(project.usesRawSourceFrame ? "Show background" : "Full frame (no background)", systemImage: project.usesRawSourceFrame ? "rectangle.inset.filled" : "rectangle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
            }

            // Cards, transitions, and more recordings (each in its own file).
            VideoTitleCardsSection(model: model)
            VideoTransitionsSection(model: model)
            VideoSourcesSection(model: model)

            VideoInspectorSection("Your look") {
                if model.styleMatchesDefault {
                    Label("New recordings use this look", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.green.opacity(0.9))
                }
                HStack(spacing: 8) {
                    Button {
                        model.saveStyleAsDefault()
                    } label: {
                        Text("Use for new recordings")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(VideoSecondaryButtonStyle())
                    .disabled(model.styleMatchesDefault)
                    Button {
                        model.resetStyle()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(VideoSecondaryButtonStyle())
                    .help("Reset to the Shotnix look")
                }
                Text("Saves the background, frame, cursor, and zoom style.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
            }
        }
        .onAppear { kind = Self.kind(of: project.background) }
        // The dice, undo, or a reset can change it from outside.
        .onChange(of: project.background) { background in kind = Self.kind(of: background) }
    }

    private var showsBlur: Bool {
        switch project.background {
        case .wallpaper, .image, .systemWallpaper: return true
        default: return false
        }
    }

    static func kind(of background: VideoBackground) -> Kind {
        switch background {
        case .wallpaper, .systemWallpaper: return .wallpaper
        case .gradient: return .gradient
        case .color: return .color
        case .image: return .image
        }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    @ViewBuilder
    private var swatchGrid: some View {
        switch kind {
        case .wallpaper:
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(VideoBackgroundCatalog.wallpapers) { wallpaper in
                    swatch(.wallpaper(wallpaper.id), help: wallpaper.title)
                }
            }
            let system = swatches.systemWallpapers
            if !system.isEmpty {
                Text("From your Mac")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
                    .padding(.top, 2)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(system, id: \.path) { url in
                        swatch(.systemWallpaper(url.path), help: url.deletingPathExtension().lastPathComponent)
                    }
                }
            }
        case .gradient:
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(VideoBackgroundCatalog.pickerGradients) { gradient in
                    swatch(.gradient(gradient.id), help: gradient.title)
                }
            }
        case .color:
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(VideoBackgroundCatalog.colors, id: \.self) { color in
                    swatch(.color(color), help: "Solid color")
                }
            }
            HStack {
                Text("Custom")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VideoEditorTheme.textPrimary)
                Spacer()
                ColorPicker("", selection: Binding(
                    get: {
                        if case .color(let rgba) = project.background { return Color(nsColor: rgba.nsColor) }
                        return Color.white
                    },
                    set: { color in
                        let rgba = VideoRGBA(nsColor: NSColor(color))
                        model.setStyle(coalesce: "bg-color") { $0.background = .color(rgba.withAlpha(1)) }
                    }
                ), supportsOpacity: false)
                .labelsHidden()
            }
        case .image:
            VStack(alignment: .leading, spacing: 10) {
                if case .image(let path) = project.background {
                    ZStack(alignment: .topTrailing) {
                        if let image = swatches.image(for: project.background) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 110)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(VideoEditorTheme.card).frame(height: 110)
                        }
                    }
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 10.5))
                        .foregroundStyle(VideoEditorTheme.textTertiary)
                        .lineLimit(1)
                }
                Button {
                    model.chooseBackgroundImage()
                } label: {
                    Label("Choose Image…", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
            }
        }
    }

    private func swatch(_ background: VideoBackground, help: String) -> some View {
        let selected = project.background == background
        return Button {
            model.setStyle { $0.background = background }
        } label: {
            ZStack {
                if let image = swatches.image(for: background) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.white.opacity(0.06)
                }
            }
            .frame(height: 42)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? Color.white : Color.white.opacity(0.1), lineWidth: selected ? 2 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
                    .padding(-3)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Cursor

struct VideoCursorInspector: View {
    @ObservedObject var model: VideoEditorModel

    private var cursor: VideoCursorSettings { model.project.cursor }

    private func binding<T>(_ keyPath: WritableKeyPath<VideoCursorSettings, T>, coalesce: String? = nil) -> Binding<T> {
        Binding(get: { model.project.cursor[keyPath: keyPath] }, set: { value in model.setStyle(coalesce: coalesce) { $0.cursor[keyPath: keyPath] = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !model.project.canRenderCursor {
                VideoCard {
                    Label(model.project.nativeCursorVisible ? "The cursor is part of this video" : "No cursor data in this video", systemImage: "cursorarrow.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VideoEditorTheme.textPrimary)
                    Text(model.project.nativeCursorVisible
                         ? "It was recorded into the pixels, so it can't be resized or smoothed. New recordings capture an editable cursor by default (Settings → Recording)."
                         : "Recordings made with Shotnix capture the pointer so it can be smoothed, resized, and hidden.")
                        .font(.system(size: 11))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VideoInspectorSection("Clicks") {
                    VideoSegmented(options: VideoCursorSettings.ClickEffect.allCases.filter { $0 != .press }.map { ($0, $0.title) }, selection: binding(\.clickEffect))
                }
            } else {
                VideoInspectorSection("Cursor") {
                    VideoToggleRow(title: "Show cursor", isOn: binding(\.visible))
                    VideoSliderRow(
                        title: "Size",
                        value: binding(\.size, coalesce: "cursor-size"),
                        range: VideoCursorSettings.sizeRange,
                        defaultValue: VideoCursorSettings().size,
                        format: { String(format: "%.1f×", $0) },
                        onEditingEnded: { model.endGesture() }
                    )
                }
                .disabled(false)

                VideoInspectorSection("Movement") {
                    VideoSegmented(options: VideoCursorSettings.Smoothing.allCases.map { ($0, $0.title) }, selection: binding(\.smoothing))
                    Text(smoothingDetail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(VideoEditorTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    VideoToggleRow(title: "Motion blur", detail: "Soft streaks on fast moves", isOn: binding(\.motionBlur))
                    VideoToggleRow(title: "Hide when idle", detail: "Fades out after a moment without movement", isOn: binding(\.hideWhenIdle))
                    VideoToggleRow(title: "Hide the move to Stop", detail: "Skips the dash to the Stop button at the end", isOn: binding(\.tidyEnding))
                }

                VideoInspectorSection("Clicks") {
                    VideoSegmented(options: VideoCursorSettings.ClickEffect.allCases.map { ($0, $0.title) }, selection: binding(\.clickEffect))
                }

                VideoInspectorSection("Appearance") {
                    VideoToggleRow(
                        title: "Always show the arrow",
                        detail: model.artwork.hasCapturedShapes ? "Never switch to the text beam or the hand" : "This recording only has the arrow",
                        isOn: binding(\.alwaysArrow)
                    )
                    .disabled(!model.artwork.hasCapturedShapes)
                }
            }

            VideoKeyboardSection(model: model)
        }
    }

    private var smoothingDetail: String {
        switch cursor.smoothing {
        case .off: return "Exactly as recorded."
        case .light: return "Removes jitter, keeps it snappy."
        case .smooth: return "Glides without lagging behind — clicks still land exactly."
        case .silky: return "Extra-fluid curves for slow, cinematic demos."
        }
    }
}

// MARK: - Zoom

struct VideoZoomInspector: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VideoCard {
                Button {
                    model.autoZoom()
                } label: {
                    Label("Auto Zoom", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoPrimaryButtonStyle())
                Text(model.project.clickEvents.isEmpty
                     ? "No clicks were recorded, so add zooms by hand: hover the zoom track and click."
                     : "Plans zooms around your \(model.project.clickEvents.count) click\(model.project.clickEvents.count == 1 ? "" : "s"). Zooms you placed by hand are kept.")
                    .font(.system(size: 11))
                    .foregroundStyle(VideoEditorTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.removeAllZooms()
                } label: {
                    Label("Remove all zooms", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle(destructive: true))
                .disabled(model.project.zoomRegions.isEmpty)
            }

            VideoInspectorSection("New zooms") {
                VideoSegmented(options: [(1.5, "1.5×"), (2.0, "2×"), (2.5, "2.5×"), (3.0, "3×")], selection: Binding(
                    get: { [1.5, 2.0, 2.5, 3.0].min { abs($0 - model.project.defaultZoomScale) < abs($1 - model.project.defaultZoomScale) } ?? 2 },
                    set: { value in model.setStyle { $0.defaultZoomScale = value } }
                ))
                Button {
                    model.applyZoomScaleToAll(model.project.defaultZoomScale)
                } label: {
                    Text("Apply to all zooms")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
                .disabled(model.project.zoomRegions.isEmpty)
            }

            VideoInspectorSection("Motion") {
                VideoSegmented(options: VideoZoomSpeed.allCases.map { ($0, $0.title) }, selection: Binding(
                    get: { model.project.zoomSpeed },
                    set: { value in model.setStyle { $0.zoomSpeed = value } }
                ))
                VideoSliderRow(
                    title: "Motion blur",
                    value: Binding(get: { model.project.motionBlur }, set: { value in model.setStyle(coalesce: "motion-blur") { $0.motionBlur = value } }),
                    range: 0...1,
                    defaultValue: VideoStylePreset.factory.motionBlur,
                    format: { "\(Int(($0 * 100).rounded()))%" },
                    detail: "Blurs fast camera moves the way a real camera does.",
                    onEditingEnded: { model.endGesture() }
                )
            }

            if !model.project.zoomRegions.isEmpty {
                VideoInspectorSection("Zooms") {
                    VStack(spacing: 4) {
                        ForEach(model.project.zoomRegions) { region in
                            if let range = model.zoomTimelineRange(region) {
                                Button {
                                    model.selection = .zoom(region.id)
                                    model.seek(to: range.lowerBound + min(1.2, (range.upperBound - range.lowerBound) / 2))
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: region.followsCursor ? "cursorarrow.motionlines" : "scope")
                                            .foregroundStyle(VideoEditorTheme.zoom)
                                            .frame(width: 16)
                                        Text(VideoEditorModel.formatScale(region.scale))
                                            .font(.system(size: 12, weight: .semibold))
                                            .monospacedDigit()
                                        Text(region.followsCursor ? "Follows cursor" : "Aim by hand")
                                            .font(.system(size: 11))
                                            .foregroundStyle(VideoEditorTheme.textSecondary)
                                        Spacer()
                                        Text("\(VideoEditorModel.timecode(range.lowerBound)) – \(VideoEditorModel.timecode(range.upperBound))")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(VideoEditorTheme.textTertiary)
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(VideoEditorTheme.card))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            Text("Hover the zoom track and click to add a zoom, or press Z at the playhead. Drag a zoom to move it; drag its edges to change how long it lasts.")
                .font(.system(size: 10.5))
                .foregroundStyle(VideoEditorTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Audio

struct VideoAudioInspector: View {
    @ObservedObject var model: VideoEditorModel

    private var audio: VideoAudioSettings { model.project.audio }

    private func binding<T>(_ keyPath: WritableKeyPath<VideoAudioSettings, T>, coalesce: String? = nil) -> Binding<T> {
        Binding(get: { model.project.audio[keyPath: keyPath] }, set: { value in model.setStyle(coalesce: coalesce) { $0.audio[keyPath: keyPath] = value } })
    }

    private func level(_ title: String, _ keyPath: WritableKeyPath<VideoAudioSettings, Double>, detail: String? = nil) -> some View {
        VideoSliderRow(
            title: title,
            value: binding(keyPath, coalesce: "volume-\(title)"),
            range: VideoAudioSettings.volumeRange,
            defaultValue: 1,
            format: { "\(Int(($0 * 100).rounded()))%" },
            detail: detail,
            onEditingEnded: { model.endGesture() }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !model.hasAudio {
                VideoCard {
                    Label("This recording has no sound", systemImage: "speaker.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VideoEditorTheme.textPrimary)
                    Text("Turn on the microphone or system audio before recording to capture sound.")
                        .font(.system(size: 11))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VideoInspectorSection("Sound") {
                    VideoToggleRow(title: "Mute video", detail: "Exports without sound — to quiet just the preview, press M", isOn: binding(\.muted))
                    Group {
                        if model.hasSeparateVoiceAndSystem {
                            level("Voice", \.voiceVolume, detail: "Your microphone")
                            level("Computer sound", \.systemVolume, detail: "What was playing on your Mac")
                        } else {
                            level("Volume", \.volume)
                        }
                    }
                    .disabled(audio.muted)
                }

                if model.canEnhanceVoice {
                    VideoInspectorSection("Voice") {
                        VideoToggleRow(
                            title: "Enhance voice",
                            detail: "Removes background noise and hum, and evens out your level — processed on this Mac",
                            isOn: binding(\.enhanceVoice)
                        )
                        if let progress = model.voiceJob {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("Cleaning up your voice…")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(VideoEditorTheme.textSecondary)
                                    Spacer()
                                    Text("\(Int((progress * 100).rounded()))%")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(VideoEditorTheme.textSecondary)
                                }
                                ProgressView(value: progress).progressViewStyle(.linear)
                            }
                        } else if let error = model.voiceError, audio.enhanceVoice {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                VideoInspectorSection("Export") {
                    VideoToggleRow(
                        title: "Even out loudness",
                        detail: "Exports at the level video sites expect (−16 LUFS) without clipping",
                        isOn: binding(\.normalizeLoudness)
                    )
                }

                Text("Select a clip on the timeline to mute it or fade it in and out.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Music and click sounds work with or without recorded sound.
            VideoMusicSection(model: model)
            VideoClickSoundSection(model: model)
        }
    }
}

// MARK: - Selection

private struct VideoSelectionHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct VideoSelectionInspector: View {
    @ObservedObject var model: VideoEditorModel
    /// The most room it takes above the tab (it scrolls past that).
    var maxHeight: CGFloat = .infinity
    @FocusState private var textFocused: Bool
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(VideoEditorTheme.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    content
                }
                .padding(16)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: VideoSelectionHeightKey.self, value: proxy.size.height)
                })
            }
            // As tall as its settings, up to the limit.
            .frame(height: min(max(contentHeight, 40), max(maxHeight - 51, 80)))
            .onPreferenceChange(VideoSelectionHeightKey.self) { contentHeight = $0 }
        }
        .background(Color.white.opacity(0.02))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected \(headerTitle)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: headerSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(headerTint)
                .padding(.leading, 6)
                .accessibilityHidden(true)
            Text(headerTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VideoEditorTheme.textPrimary)
            Spacer()
            Button {
                model.deleteSelection()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(VideoToolButtonStyle(destructive: true))
            .help("Delete (⌫)")
            .accessibilityLabel("Delete")
            Button {
                model.selection = .none
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(VideoToolButtonStyle())
            .help("Done (Esc)")
            .accessibilityLabel("Done")
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
    }

    private var headerTitle: String {
        if !model.extraSelection.isEmpty { return "\(model.selectedItems.count) selected" }
        switch model.selection {
        case .zoom: return "Zoom"
        case .clip(let id): return "Clip \((model.segments.firstIndex { $0.id == id } ?? 0) + 1)"
        case .overlay: return model.selectedOverlay?.kind.title ?? "Annotation"
        case .click: return "Click"
        case .caption: return "Caption"
        case .keystroke: return "Shortcut"
        case .cameraLayout: return "Camera layout"
        case .range(let range): return "Selected \(VideoEditorModel.format(range.duration))"
        case .none: return ""
        }
    }

    private var headerSymbol: String {
        if !model.extraSelection.isEmpty { return "square.stack.3d.up" }
        switch model.selection {
        case .zoom: return "plus.magnifyingglass"
        case .clip: return "film"
        case .overlay: return model.selectedOverlay?.kind.icon ?? "text.bubble"
        case .click: return "cursorarrow.click.2"
        case .caption: return "captions.bubble"
        case .keystroke: return "keyboard"
        case .cameraLayout: return "person.crop.rectangle"
        case .range: return "selection.pin.in.out"
        case .none: return ""
        }
    }

    private var headerTint: Color {
        switch model.selection {
        case .zoom: return VideoEditorTheme.zoom
        case .clip: return VideoEditorTheme.clip
        case .overlay: return model.selectedOverlay.map { VideoEditorTheme.overlayTint($0.kind) } ?? VideoEditorTheme.textSecondary
        case .range: return Color.red
        case .caption: return VideoEditorTheme.caption
        case .keystroke: return VideoEditorTheme.keys
        case .cameraLayout: return VideoEditorTheme.camera
        default: return VideoEditorTheme.textSecondary
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.extraSelection.isEmpty {
            multipleContent
        } else {
            singleContent
        }
    }

    /// Several items: what they are, and what can be done with all of them.
    private var multipleContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            let counts = Dictionary(grouping: model.selectedItems, by: Self.kindName).map { "\($0.value.count) \($0.key)\($0.value.count == 1 ? "" : "s")" }.sorted()
            Text(counts.joined(separator: " · "))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VideoEditorTheme.textPrimary)
            Text("Drag one of them on the timeline to move them all together; ⌫ removes them all. ⇧- or ⌘-click adds or takes one out.")
                .font(.system(size: 11))
                .foregroundStyle(VideoEditorTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive) {
                model.deleteSelectedItems()
            } label: {
                Label("Remove all \(model.selectedItems.count)", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VideoSecondaryButtonStyle(destructive: true))
        }
    }

    private static func kindName(_ item: VideoEditorModel.Selection) -> String {
        switch item {
        case .zoom: return "zoom"
        case .clip: return "clip"
        case .overlay: return "annotation"
        case .click: return "click"
        case .caption: return "caption"
        case .keystroke: return "shortcut"
        case .cameraLayout: return "camera layout"
        case .range, .none: return "part"
        }
    }

    @ViewBuilder
    private var singleContent: some View {
        switch model.selection {
        case .zoom(let id):
            if let zoom = model.project.zoomRegions.first(where: { $0.id == id }) {
                zoomEditor(zoom)
            }
        case .clip(let id):
            if let segment = model.segments.first(where: { $0.id == id }) {
                clipEditor(segment)
            }
        case .overlay(let id):
            if let overlay = model.project.overlayEffects.first(where: { $0.id == id }) {
                overlayEditor(overlay)
            }
        case .click(let id):
            if let click = model.project.clickEvents.first(where: { $0.id == id }) {
                Text("Recorded at \(VideoEditorModel.timecode(model.timelineTime(forSource: click.time) ?? click.time)). Drag its dot on the timeline to retime it; ripples and Auto Zoom follow.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(VideoEditorTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .caption(let id):
            if let line = model.project.captions.first(where: { $0.id == id }) {
                captionEditor(line)
            }
        case .keystroke(let id):
            if let event = model.project.keystrokes.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(event.keys.joined(separator: " "))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(VideoEditorTheme.textPrimary)
                    Text("Pressed at \(VideoEditorModel.timecode(model.timelineTime(forSource: event.time) ?? event.time)). Press ⌫ to hide it from the video — handy for a stray ⌘Tab.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .cameraLayout(let id):
            if let region = model.project.cameraLayouts.first(where: { $0.id == id }) {
                VideoInspectorSection("Layout") {
                    ForEach(VideoCameraLayoutRegion.Layout.allCases) { layout in
                        Button {
                            model.setCameraLayout(id, to: layout)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: layout.symbol)
                                    .frame(width: 20)
                                Text(layout.title)
                                Spacer()
                                if region.layout == layout {
                                    Image(systemName: "checkmark").foregroundStyle(VideoEditorTheme.camera)
                                }
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(VideoEditorTheme.textPrimary)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(region.layout == layout ? VideoEditorTheme.camera.opacity(0.18) : Color.white.opacity(0.04)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Drag the block on the Camera lane to move it, or its edges to change how long it lasts. Each change eases in and out.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .range(let range):
            VStack(alignment: .leading, spacing: 12) {
                Text("\(VideoEditorModel.timecode(range.start)) → \(VideoEditorModel.timecode(range.end))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VideoEditorTheme.textPrimary)
                Button {
                    model.deleteRange(range)
                } label: {
                    Label("Cut this part", systemImage: "scissors")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoPrimaryButtonStyle())
                Text("Removed parts can be restored from the yellow marker on the timeline.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
            }
            // Or change just this part.
            VideoInspectorSection("Speed of this part") {
                let current = model.rangeSpeed(range)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach([0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 8.0, 16.0], id: \.self) { speed in
                        let selected = current.map { abs($0 - speed) < 0.01 } ?? false
                        Button {
                            model.setRangeSpeed(range, speed)
                        } label: {
                            Text(VideoEditorModel.formatScale(speed))
                                .font(.system(size: 11.5, weight: selected ? .bold : .semibold))
                                .foregroundStyle(selected ? Color.black : VideoEditorTheme.textPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 26)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? VideoEditorTheme.clip : VideoEditorTheme.card))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(VideoEditorModel.formatScale(speed)) speed")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            VideoInspectorSection("Sound") {
                VideoToggleRow(title: "Mute this part", isOn: Binding(get: { model.rangeIsMuted(range) }, set: { _ in model.toggleRangeMute(range) }))
            }
        case .none:
            EmptyView()
        }
    }

    // MARK: Caption

    @ViewBuilder
    private func captionEditor(_ line: VideoCaptionLine) -> some View {
        VideoInspectorSection("Text") {
            TextField("Caption", text: Binding(get: { line.text }, set: { model.updateCaption(line.id, text: $0) }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(2...6)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(VideoEditorTheme.cardStroke, lineWidth: 1))
                .focused($textFocused)
                .onSubmit { model.endGesture() }
        }
        VideoInspectorSection("Timing") {
            timingRow("Starts", time: line.start) { model.setCaptionTiming(line.id, start: $0) }
            timingRow("Ends", time: line.end) { model.setCaptionTiming(line.id, end: $0) }
            Button {
                let now = model.sourceTime(forTimeline: model.clock.time)
                model.setCaptionTiming(line.id, start: now, end: max(line.end, now + 0.5))
                model.endGesture()
            } label: {
                Label("Start at the playhead", systemImage: "arrow.right.to.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VideoSecondaryButtonStyle())
        }
    }

    private func timingRow(_ title: String, time: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VideoEditorTheme.textPrimary)
            Spacer()
            Button {
                set(time - 0.1)
                model.endGesture()
            } label: {
                Image(systemName: "minus").font(.system(size: 9, weight: .bold)).frame(width: 22, height: 20)
            }
            .buttonStyle(VideoToolButtonStyle())
            .help("0.1s earlier")
            Text(VideoEditorModel.timecode(model.timelineTime(forSource: time) ?? time))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(VideoEditorTheme.textSecondary)
                .frame(minWidth: 52)
            Button {
                set(time + 0.1)
                model.endGesture()
            } label: {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold)).frame(width: 22, height: 20)
            }
            .buttonStyle(VideoToolButtonStyle())
            .help("0.1s later")
        }
    }

    // MARK: Zoom

    @ViewBuilder
    private func zoomEditor(_ zoom: VideoZoomRegion) -> some View {
        VideoInspectorSection("Zoom level") {
            VideoSliderRow(
                title: "Level",
                value: Binding(get: { zoom.scale }, set: { value in model.updateZoom(zoom.id, coalesce: "scale-\(zoom.id)") { $0.scale = value } }),
                range: VideoZoomRegion.scaleRange,
                defaultValue: model.project.defaultZoomScale,
                format: { String(format: "%.2g×", $0) },
                onEditingEnded: { model.endGesture() }
            )
            HStack(spacing: 6) {
                ForEach([1.5, 2.0, 2.5, 3.0], id: \.self) { value in
                    let selected = abs(zoom.scale - value) < 0.02
                    Button {
                        model.updateZoom(zoom.id) { $0.scale = value }
                    } label: {
                        Text(VideoEditorModel.formatScale(value))
                            .font(.system(size: 11.5, weight: selected ? .bold : .semibold))
                            .foregroundStyle(selected ? Color.white : VideoEditorTheme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? VideoEditorTheme.zoom : VideoEditorTheme.card))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Zoom to \(VideoEditorModel.formatScale(value)) (key \(["1.5×": "2", "2×": "3", "2.5×": "4", "3×": "5"][VideoEditorModel.formatScale(value)] ?? ""))")
                }
            }
            Button {
                model.applyZoomScaleToAll(zoom.scale)
            } label: {
                Text("Use this level for every zoom")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VideoSecondaryButtonStyle())
        }

        VideoInspectorSection("Framing") {
            VideoSegmented(options: [(true, "Follow cursor"), (false, "Aim by hand")], selection: Binding(
                get: { zoom.followsCursor },
                set: { value in
                    model.updateZoom(zoom.id) { $0.followsCursor = value }
                    if !value { model.pause() }
                }
            ))
            if zoom.followsCursor {
                Text("The camera keeps your cursor in view and glides after it.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
            } else {
                Text("Drag the frame on the preview to aim; drag its corners to zoom in or out.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
                Button {
                    model.updateZoom(zoom.id) { $0.focusX = 0.5; $0.focusY = 0.5 }
                } label: {
                    Text("Center")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
            }
        }

        if let range = model.zoomTimelineRange(zoom) {
            VideoInspectorSection("Timing") {
                HStack {
                    Text("\(VideoEditorModel.timecode(range.lowerBound)) → \(VideoEditorModel.timecode(range.upperBound))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(VideoEditorTheme.textPrimary)
                    Spacer()
                    Text(VideoEditorModel.format(range.upperBound - range.lowerBound))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                }
                Button {
                    model.duplicateZoom(zoom.id)
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
            }
        }
    }

    // MARK: Clip

    @ViewBuilder
    private func clipEditor(_ segment: VideoDemoTimelineSegment) -> some View {
        VideoInspectorSection("Speed") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach([0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 8.0, 16.0], id: \.self) { speed in
                    let selected = abs(segment.clip.normalizedSpeed - speed) < 0.01
                    Button {
                        model.setClipSpeed(segment.id, speed)
                        model.endGesture()
                    } label: {
                        Text(VideoEditorModel.formatScale(speed))
                            .font(.system(size: 11.5, weight: selected ? .bold : .semibold))
                            .foregroundStyle(selected ? Color.black : VideoEditorTheme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? VideoEditorTheme.clip : VideoEditorTheme.card))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("\(VideoEditorModel.format(segment.clip.sourceDuration)) of recording plays in \(VideoEditorModel.format(segment.duration)).")
                .font(.system(size: 10.5))
                .foregroundStyle(VideoEditorTheme.textTertiary)
        }

        VideoInspectorSection("Sound") {
            VideoToggleRow(title: "Mute this clip", isOn: Binding(get: { segment.clip.muted }, set: { model.setClipMuted(segment.id, $0) }))
            VideoSliderRow(
                title: "Fade in",
                value: Binding(get: { segment.clip.fadeIn }, set: { model.setClipFade(segment.id, fadeIn: $0) }),
                range: 0...max(min(segment.duration / 2, 3), 0.1),
                defaultValue: 0,
                format: { String(format: "%.1fs", $0) },
                onEditingEnded: { model.endGesture() }
            )
            VideoSliderRow(
                title: "Fade out",
                value: Binding(get: { segment.clip.fadeOut }, set: { model.setClipFade(segment.id, fadeOut: $0) }),
                range: 0...max(min(segment.duration / 2, 3), 0.1),
                defaultValue: 0,
                format: { String(format: "%.1fs", $0) },
                onEditingEnded: { model.endGesture() }
            )
        }

        // How the cut into this clip plays (VideoTransitions.swift).
        VideoClipTransitionSection(model: model, segment: segment)

        VideoInspectorSection("Edit") {
            HStack(spacing: 8) {
                Button {
                    model.trimSelectedClipToPlayhead(leading: true)
                } label: {
                    Label("Start here", systemImage: "arrow.left.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
                .help("Trim the clip's start to the playhead (I)")
                Button {
                    model.trimSelectedClipToPlayhead(leading: false)
                } label: {
                    Label("End here", systemImage: "arrow.right.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
                .help("Trim the clip's end to the playhead (O)")
            }
            Button {
                model.splitAtPlayhead()
            } label: {
                Label("Split at playhead", systemImage: "scissors")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VideoSecondaryButtonStyle())
            if let index = model.segments.firstIndex(where: { $0.id == segment.id }), model.segments.count > 1 {
                // Or drag the clip by its name on the timeline.
                HStack(spacing: 8) {
                    Button {
                        model.moveClip(segment.id, toIndex: index - 1)
                    } label: {
                        Label("Move earlier", systemImage: "arrow.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(VideoSecondaryButtonStyle())
                    .disabled(index == 0)
                    Button {
                        model.moveClip(segment.id, toIndex: index + 1)
                    } label: {
                        Label("Move later", systemImage: "arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(VideoSecondaryButtonStyle())
                    .disabled(index >= model.segments.count - 1)
                }
            }
        }
    }

    // MARK: Overlay

    @ViewBuilder
    private func overlayEditor(_ overlay: VideoDemoOverlayEffect) -> some View {
        if overlay.kind == .image {
            VideoImageOverlayInspector(model: model, overlay: overlay)
        }
        if overlay.kind == .text {
            VideoInspectorSection("Text") {
                TextField("Text", text: Binding(get: { overlay.text }, set: { value in model.updateOverlay(overlay.id, coalesce: "text-\(overlay.id)") { $0.text = value } }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1...4)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.3)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(VideoEditorTheme.cardStroke, lineWidth: 1))
                    .focused($textFocused)
                    .onChange(of: model.textEditRequest) { _ in textFocused = true }
                // The size of the letters, apart from the box's width.
                VideoSliderRow(
                    title: "Size",
                    value: Binding(get: { model.textSize(of: overlay) }, set: { model.setTextSize($0, of: overlay.id) }),
                    range: 14...64,
                    format: { "\(Int($0.rounded()))" },
                    onEditingEnded: { model.endGesture() }
                )
            }
        }
        if overlay.kind.hasColor {
            VideoInspectorSection(overlay.kind == .text ? "Tag color" : "Color") {
                VideoOverlayColorPicker(model: model, overlay: overlay)
            }
        }
        if overlay.kind == .arrow || overlay.kind == .highlight {
            VideoInspectorSection("Thickness") {
                VideoSegmented(
                    options: VideoOverlayThickness.allCases.map { ($0, $0.title) },
                    selection: Binding(get: { overlay.thickness }, set: { model.setOverlayThickness(overlay.id, $0) })
                )
            }
        }
        if overlay.kind == .arrow {
            Button {
                model.flipArrow(overlay.id)
            } label: {
                Label("Turn around", systemImage: "arrow.left.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VideoSecondaryButtonStyle())
            .help("Swap the arrow's head and tail")
        }
        if overlay.kind == .spotlight {
            VideoInspectorSection("Shape") {
                VideoSegmented(
                    options: VideoOverlayShape.allCases.map { ($0, $0.title) },
                    selection: Binding(get: { overlay.shape ?? .rectangle }, set: { model.setOverlayShape(overlay.id, $0) })
                )
            }
        }
        // Images have their own placement controls (VideoImageOverlays.swift).
        if overlay.kind != .image {
            VideoInspectorSection("Placement") {
                Text(placementHelp(overlay.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(VideoEditorTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func placementHelp(_ kind: VideoDemoOverlayEffectKind) -> String {
        switch kind {
        case .blur: return "Drag the box on the preview over anything private. Blur follows zooms and stays until its bar ends."
        case .arrow: return "Drag the arrow on the preview to move it; drag its head or tail to point it anywhere. Its bar on the timeline sets when it shows."
        case .spotlight: return "Drag the spot on the preview; drag a corner to resize it. Everything around it dims while its bar on the timeline runs."
        case .text: return "Drag it on the preview to move it; drag a corner to resize; double-click it to type. Its bar on the timeline sets when it shows."
        default: return "Drag it on the preview to move it; drag a corner to resize. Its bar on the timeline sets when it shows."
        }
    }
}
