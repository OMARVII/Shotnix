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
                        // Never wraps: a longer name ("Untertitel") takes a
                        // little room from the others.
                        Text(tab.title)
                            .font(.system(size: 10, weight: .semibold))
                            .fixedSize()
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
                .help(tab == .captions && model.suggestsTranscript ? L("Your narration can become captions — transcribe it here") : tab.help)
                .accessibilityLabel(tab.title)
                .accessibilityHint(tab.help)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Inspector tabs"))
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
            VideoInspectorSection(L("Background"), trailing: {
                Button {
                    model.shuffleBackground()
                } label: {
                    Image(systemName: "dice")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(L("Shuffle the background"))
                .accessibilityLabel(L("Shuffle the background"))
            }) {
                VideoSegmented(options: [(.wallpaper, L("Wallpaper")), (.gradient, L("Gradient")), (.color, L("Color")), (.image, L("Image"))], selection: $kind)
                swatchGrid
                if showsBlur {
                    VideoSliderRow(
                        title: L("Blur"),
                        value: Binding(get: { project.backgroundBlur }, set: { value in model.setStyle(coalesce: "bg-blur") { $0.backgroundBlur = value } }),
                        range: 0...1,
                        defaultValue: 0,
                        format: { VideoEditorFormat.percent($0) },
                        onEditingEnded: { model.endGesture() }
                    )
                }
            }

            VideoInspectorSection(L("Frame")) {
                VideoSliderRow(
                    title: L("Padding"),
                    value: Binding(get: { project.padding }, set: { value in model.setStyle(coalesce: "padding") { $0.padding = value } }),
                    range: 0...0.25,
                    defaultValue: VideoStylePreset.factory.padding,
                    format: { "\(Int(($0 * 400).rounded()))" },
                    onEditingEnded: { model.endGesture() }
                )
                VideoSliderRow(
                    title: L("Roundness"),
                    value: Binding(get: { project.cornerRadius }, set: { value in model.setStyle(coalesce: "radius") { $0.cornerRadius = value } }),
                    range: 0...60,
                    defaultValue: VideoStylePreset.factory.cornerRadius,
                    format: { "\(Int($0.rounded()))" },
                    onEditingEnded: { model.endGesture() }
                )
                VideoSliderRow(
                    title: L("Shadow"),
                    value: Binding(get: { project.shadow }, set: { value in model.setStyle(coalesce: "shadow") { $0.shadow = value } }),
                    range: 0...1,
                    defaultValue: VideoStylePreset.factory.shadow,
                    format: { VideoEditorFormat.percent($0) },
                    onEditingEnded: { model.endGesture() }
                )
                VideoToggleRow(
                    title: L("Edge highlight"),
                    detail: L("A hairline that separates dark recordings from the background"),
                    isOn: Binding(get: { project.outline }, set: { value in model.setStyle { $0.outline = value } })
                )
                Button {
                    model.setStyle { project in
                        project.padding = project.usesRawSourceFrame ? VideoStylePreset.factory.padding : 0
                    }
                } label: {
                    Label(project.usesRawSourceFrame ? L("Show background") : L("Full frame (no background)"), systemImage: project.usesRawSourceFrame ? "rectangle.inset.filled" : "rectangle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
            }

            // Cards, transitions, and more recordings (each in its own file).
            VideoTitleCardsSection(model: model)
            VideoTransitionsSection(model: model)
            VideoSourcesSection(model: model)

            VideoInspectorSection(L("Your look")) {
                if model.styleMatchesDefault {
                    Label(L("New recordings use this look"), systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.green.opacity(0.9))
                }
                HStack(spacing: 8) {
                    Button {
                        model.saveStyleAsDefault()
                    } label: {
                        Text(L("Use for new recordings"))
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
                    .help(L("Reset to the Shotnix look"))
                }
                Text(L("Saves the background, frame, cursor, and zoom style."))
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
                Text(L("From your Mac"))
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
                    swatch(.color(color), help: L("Solid color"))
                }
            }
            HStack {
                Text(L("Custom"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VideoEditorTheme.textPrimary)
                Spacer()
                ColorPicker(L("Custom color"), selection: Binding(
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
                    Label(L("Choose Image…"), systemImage: "photo")
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
                    Label(model.project.nativeCursorVisible ? L("The cursor is part of this video") : L("No cursor data in this video"), systemImage: "cursorarrow.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VideoEditorTheme.textPrimary)
                    Text(model.project.nativeCursorVisible
                         ? L("It was recorded into the pixels, so it can't be resized or smoothed. New recordings capture an editable cursor by default (Settings → Recording).")
                         : L("Recordings made with Shotnix capture the pointer so it can be smoothed, resized, and hidden."))
                        .font(.system(size: 11))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VideoInspectorSection(L("Clicks")) {
                    VideoSegmented(options: VideoCursorSettings.ClickEffect.allCases.filter { $0 != .press }.map { ($0, $0.title) }, selection: binding(\.clickEffect))
                }
            } else {
                VideoInspectorSection(L("Cursor")) {
                    VideoToggleRow(title: L("Show cursor"), isOn: binding(\.visible))
                    VideoSliderRow(
                        title: L("Size"),
                        value: binding(\.size, coalesce: "cursor-size"),
                        range: VideoCursorSettings.sizeRange,
                        defaultValue: VideoCursorSettings().size,
                        format: { VideoEditorModel.formatScale($0) },
                        onEditingEnded: { model.endGesture() }
                    )
                }
                .disabled(false)

                VideoInspectorSection(L("Movement")) {
                    VideoSegmented(options: VideoCursorSettings.Smoothing.allCases.map { ($0, $0.title) }, selection: binding(\.smoothing))
                    Text(smoothingDetail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(VideoEditorTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    VideoToggleRow(title: L("Motion blur"), detail: L("Soft streaks on fast moves"), isOn: binding(\.motionBlur))
                    VideoToggleRow(title: L("Hide when idle"), detail: L("Fades out after a moment without movement"), isOn: binding(\.hideWhenIdle))
                    VideoToggleRow(title: L("Hide the move to Stop"), detail: L("Skips the dash to the Stop button at the end"), isOn: binding(\.tidyEnding))
                }

                VideoInspectorSection(L("Clicks")) {
                    VideoSegmented(options: VideoCursorSettings.ClickEffect.allCases.map { ($0, $0.title) }, selection: binding(\.clickEffect))
                }

                VideoInspectorSection(L("Appearance")) {
                    VideoToggleRow(
                        title: L("Always show the arrow"),
                        detail: model.artwork.hasCapturedShapes ? L("Never switch to the text beam or the hand") : L("This recording only has the arrow"),
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
        case .off: return L("Exactly as recorded.")
        case .light: return L("Removes jitter, keeps it snappy.")
        case .smooth: return L("Glides without lagging behind — clicks still land exactly.")
        case .silky: return L("Extra-fluid curves for slow, cinematic demos.")
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
                    Label(L("Auto Zoom"), systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoPrimaryButtonStyle())
                Text(model.project.clickEvents.isEmpty
                     ? L("No clicks were recorded, so add zooms by hand: hover the zoom track and click.")
                     : L("Plans zooms around your \(model.project.clickEvents.count) clicks. Zooms you placed by hand are kept."))
                    .font(.system(size: 11))
                    .foregroundStyle(VideoEditorTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.removeAllZooms()
                } label: {
                    Label(L("Remove all zooms"), systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle(destructive: true))
                .disabled(model.project.zoomRegions.isEmpty)
            }

            VideoInspectorSection(L("New zooms")) {
                VideoSegmented(options: [1.5, 2.0, 2.5, 3.0].map { ($0, VideoEditorModel.formatScale($0)) }, selection: Binding(
                    get: { [1.5, 2.0, 2.5, 3.0].min { abs($0 - model.project.defaultZoomScale) < abs($1 - model.project.defaultZoomScale) } ?? 2 },
                    set: { value in model.setStyle { $0.defaultZoomScale = value } }
                ))
                Button {
                    model.applyZoomScaleToAll(model.project.defaultZoomScale)
                } label: {
                    Text(L("Apply to all zooms"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
                .disabled(model.project.zoomRegions.isEmpty)
            }

            VideoInspectorSection(L("Motion")) {
                VideoSegmented(options: VideoZoomSpeed.allCases.map { ($0, $0.title) }, selection: Binding(
                    get: { model.project.zoomSpeed },
                    set: { value in model.setStyle { $0.zoomSpeed = value } }
                ))
                VideoSliderRow(
                    title: L("Motion blur"),
                    value: Binding(get: { model.project.motionBlur }, set: { value in model.setStyle(coalesce: "motion-blur") { $0.motionBlur = value } }),
                    range: 0...1,
                    defaultValue: VideoStylePreset.factory.motionBlur,
                    format: { VideoEditorFormat.percent($0) },
                    detail: L("Blurs fast camera moves the way a real camera does."),
                    onEditingEnded: { model.endGesture() }
                )
            }

            if !model.project.zoomRegions.isEmpty {
                VideoInspectorSection(L("Zooms")) {
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
                                        Text(region.followsCursor ? L("Follows cursor") : L("Aim by hand"))
                                            .font(.system(size: 11))
                                            .foregroundStyle(VideoEditorTheme.textSecondary)
                                        Spacer()
                                        Text(verbatim: "\(VideoEditorModel.timecode(range.lowerBound)) – \(VideoEditorModel.timecode(range.upperBound))")
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

            Text(L("Hover the zoom track and click to add a zoom, or press Z at the playhead. Drag a zoom to move it; drag its edges to change how long it lasts."))
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
            format: { VideoEditorFormat.percent($0) },
            detail: detail,
            onEditingEnded: { model.endGesture() }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !model.hasAudio {
                VideoCard {
                    Label(L("This recording has no sound"), systemImage: "speaker.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VideoEditorTheme.textPrimary)
                    Text(L("Turn on the microphone or system audio before recording to capture sound."))
                        .font(.system(size: 11))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VideoInspectorSection(L("Sound")) {
                    VideoToggleRow(title: L("Mute video"), detail: L("Exports without sound — to quiet just the preview, press M"), isOn: binding(\.muted))
                    Group {
                        if model.hasSeparateVoiceAndSystem {
                            level(L("Voice"), \.voiceVolume, detail: L("Your microphone"))
                            level(L("Computer sound"), \.systemVolume, detail: L("What was playing on your Mac"))
                        } else {
                            level(L("Volume"), \.volume)
                        }
                    }
                    .disabled(audio.muted)
                }

                if model.canEnhanceVoice {
                    VideoInspectorSection(L("Voice")) {
                        VideoToggleRow(
                            title: L("Enhance voice"),
                            detail: L("Removes background noise and hum, and evens out your level — processed on this Mac"),
                            isOn: binding(\.enhanceVoice)
                        )
                        if let progress = model.voiceJob {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(L("Cleaning up your voice…"))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(VideoEditorTheme.textSecondary)
                                    Spacer()
                                    Text(VideoEditorFormat.percent(progress))
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

                VideoInspectorSection(L("Export")) {
                    VideoToggleRow(
                        title: L("Even out loudness"),
                        detail: L("Exports at the level video sites expect (−16 LUFS) without clipping"),
                        isOn: binding(\.normalizeLoudness)
                    )
                }

                Text(L("Select a clip on the timeline to mute it or fade it in and out."))
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
        .accessibilityLabel(L("Selected \(headerTitle)"))
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
            .help(L("Delete (⌫)"))
            .accessibilityLabel(L("Delete"))
            Button {
                model.selection = .none
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(VideoToolButtonStyle())
            .help(L("Done (Esc)"))
            .accessibilityLabel(L("Done"))
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
    }

    private var headerTitle: String {
        if !model.extraSelection.isEmpty { return L("\(model.selectedItems.count) selected") }
        switch model.selection {
        case .zoom: return L("Zoom")
        case .clip(let id): return L("Clip \((model.segments.firstIndex { $0.id == id } ?? 0) + 1)")
        case .overlay: return model.selectedOverlay?.kind.title ?? L("Annotation")
        case .click: return L("Click")
        case .caption: return L("Caption")
        case .keystroke: return L("Shortcut")
        case .cameraLayout: return L("Camera layout")
        case .range(let range): return L("Selected \(VideoEditorModel.format(range.duration))")
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
            let counts = Dictionary(grouping: model.selectedItems, by: ItemKind.init).map { Self.count($0.value.count, of: $0.key) }.sorted()
            Text(counts.joined(separator: " · "))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VideoEditorTheme.textPrimary)
            Text(L("Drag one of them on the timeline to move them all together; ⌫ removes them all. ⇧- or ⌘-click adds or takes one out."))
                .font(.system(size: 11))
                .foregroundStyle(VideoEditorTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive) {
                model.deleteSelectedItems()
            } label: {
                Label(L("Remove all \(model.selectedItems.count)"), systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VideoSecondaryButtonStyle(destructive: true))
        }
    }

    private enum ItemKind: Hashable {
        case zoom, clip, annotation, click, caption, shortcut, cameraLayout, part

        init(_ item: VideoEditorModel.Selection) {
            switch item {
            case .zoom: self = .zoom
            case .clip: self = .clip
            case .overlay: self = .annotation
            case .click: self = .click
            case .caption: self = .caption
            case .keystroke: self = .shortcut
            case .cameraLayout: self = .cameraLayout
            case .range, .none: self = .part
            }
        }
    }

    /// "2 zooms", "1 clip": one whole phrase for each kind, so each
    /// language puts the number and the plural where it belongs.
    private static func count(_ count: Int, of kind: ItemKind) -> String {
        switch kind {
        case .zoom: return L("\(count) zooms")
        case .clip: return L("\(count) clips")
        case .annotation: return L("\(count) annotations")
        case .click: return L("\(count) clicks")
        case .caption: return L("\(count) captions")
        case .shortcut: return L("\(count) shortcuts")
        case .cameraLayout: return L("\(count) camera layouts")
        case .part: return L("\(count) parts")
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
                Text(L("Recorded at \(VideoEditorModel.timecode(model.timelineTime(forSource: click.time) ?? click.time)). Drag its dot on the timeline to retime it; ripples and Auto Zoom follow."))
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
                    Text(L("Pressed at \(VideoEditorModel.timecode(model.timelineTime(forSource: event.time) ?? event.time)). Press ⌫ to hide it from the video — handy for a stray ⌘Tab."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .cameraLayout(let id):
            if let region = model.project.cameraLayouts.first(where: { $0.id == id }) {
                VideoInspectorSection(L("Layout")) {
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
                Text(L("Drag the block on the Camera lane to move it, or its edges to change how long it lasts. Each change eases in and out."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .range(let range):
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: "\(VideoEditorModel.timecode(range.start)) → \(VideoEditorModel.timecode(range.end))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VideoEditorTheme.textPrimary)
                Button {
                    model.deleteRange(range)
                } label: {
                    Label(L("Cut this part"), systemImage: "scissors")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoPrimaryButtonStyle())
                Text(L("Removed parts can be restored from the yellow marker on the timeline."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
            }
            // Or change just this part.
            VideoInspectorSection(L("Speed of this part")) {
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
                        .accessibilityLabel(L("\(VideoEditorModel.formatScale(speed)) speed"))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            VideoInspectorSection(L("Sound")) {
                VideoToggleRow(title: L("Mute this part"), isOn: Binding(get: { model.rangeIsMuted(range) }, set: { _ in model.toggleRangeMute(range) }))
            }
        case .none:
            EmptyView()
        }
    }

    // MARK: Caption

    @ViewBuilder
    private func captionEditor(_ line: VideoCaptionLine) -> some View {
        VideoInspectorSection(L("Text")) {
            TextField(L("Caption"), text: Binding(get: { line.text }, set: { model.updateCaption(line.id, text: $0) }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(2...6)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(VideoEditorTheme.cardStroke, lineWidth: 1))
                .focused($textFocused)
                .onSubmit { model.endGesture() }
        }
        VideoInspectorSection(L("Timing")) {
            timingRow(L("Starts"), time: line.start) { model.setCaptionTiming(line.id, start: $0) }
            timingRow(L("Ends"), time: line.end) { model.setCaptionTiming(line.id, end: $0) }
            Button {
                let now = model.sourceTime(forTimeline: model.clock.time)
                model.setCaptionTiming(line.id, start: now, end: max(line.end, now + 0.5))
                model.endGesture()
            } label: {
                Label(L("Start at the playhead"), systemImage: "arrow.right.to.line")
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
            .help(L("0.1s earlier"))
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
            .help(L("0.1s later"))
        }
    }

    // MARK: Zoom

    @ViewBuilder
    private func zoomEditor(_ zoom: VideoZoomRegion) -> some View {
        VideoInspectorSection(L("Zoom level")) {
            VideoSliderRow(
                title: L("Level"),
                value: Binding(get: { zoom.scale }, set: { value in model.updateZoom(zoom.id, coalesce: "scale-\(zoom.id)") { $0.scale = value } }),
                range: VideoZoomRegion.scaleRange,
                defaultValue: model.project.defaultZoomScale,
                format: { VideoEditorModel.formatScale($0) },
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
                    .help(L("Zoom to \(VideoEditorModel.formatScale(value)) (key \([1.5: "2", 2.0: "3", 2.5: "4", 3.0: "5"][value] ?? ""))"))
                }
            }
            Button {
                model.applyZoomScaleToAll(zoom.scale)
            } label: {
                Text(L("Use this level for every zoom"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VideoSecondaryButtonStyle())
        }

        VideoInspectorSection(L("Framing")) {
            VideoSegmented(options: [(true, L("Follow cursor")), (false, L("Aim by hand"))], selection: Binding(
                get: { zoom.followsCursor },
                set: { value in
                    model.updateZoom(zoom.id) { $0.followsCursor = value }
                    if !value { model.pause() }
                }
            ))
            if zoom.followsCursor {
                Text(L("The camera keeps your cursor in view and glides after it."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
            } else {
                Text(L("Drag the frame on the preview to aim; drag its corners to zoom in or out."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
                Button {
                    model.updateZoom(zoom.id) { $0.focusX = 0.5; $0.focusY = 0.5 }
                } label: {
                    Text(L("Center"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
            }
        }

        if let range = model.zoomTimelineRange(zoom) {
            VideoInspectorSection(L("Timing")) {
                HStack {
                    Text(verbatim: "\(VideoEditorModel.timecode(range.lowerBound)) → \(VideoEditorModel.timecode(range.upperBound))")
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
                    Label(L("Duplicate"), systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
            }
        }
    }

    // MARK: Clip

    @ViewBuilder
    private func clipEditor(_ segment: VideoDemoTimelineSegment) -> some View {
        VideoInspectorSection(L("Speed")) {
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
            Text(L("\(VideoEditorModel.format(segment.clip.sourceDuration)) of recording plays in \(VideoEditorModel.format(segment.duration))."))
                .font(.system(size: 10.5))
                .foregroundStyle(VideoEditorTheme.textTertiary)
        }

        VideoInspectorSection(L("Sound")) {
            VideoToggleRow(title: L("Mute this clip"), isOn: Binding(get: { segment.clip.muted }, set: { model.setClipMuted(segment.id, $0) }))
            VideoSliderRow(
                title: L("Fade in"),
                value: Binding(get: { segment.clip.fadeIn }, set: { model.setClipFade(segment.id, fadeIn: $0) }),
                range: 0...max(min(segment.duration / 2, 3), 0.1),
                defaultValue: 0,
                format: { VideoEditorModel.format($0) },
                onEditingEnded: { model.endGesture() }
            )
            VideoSliderRow(
                title: L("Fade out"),
                value: Binding(get: { segment.clip.fadeOut }, set: { model.setClipFade(segment.id, fadeOut: $0) }),
                range: 0...max(min(segment.duration / 2, 3), 0.1),
                defaultValue: 0,
                format: { VideoEditorModel.format($0) },
                onEditingEnded: { model.endGesture() }
            )
        }

        // How the cut into this clip plays (VideoTransitions.swift).
        VideoClipTransitionSection(model: model, segment: segment)

        VideoInspectorSection(L("Edit")) {
            HStack(spacing: 8) {
                Button {
                    model.trimSelectedClipToPlayhead(leading: true)
                } label: {
                    Label(L("Start here"), systemImage: "arrow.left.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
                .help(L("Trim the clip's start to the playhead (I)"))
                Button {
                    model.trimSelectedClipToPlayhead(leading: false)
                } label: {
                    Label(L("End here"), systemImage: "arrow.right.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
                .help(L("Trim the clip's end to the playhead (O)"))
            }
            Button {
                model.splitAtPlayhead()
            } label: {
                Label(L("Split at playhead"), systemImage: "scissors")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VideoSecondaryButtonStyle())
            if let index = model.segments.firstIndex(where: { $0.id == segment.id }), model.segments.count > 1 {
                // Or drag the clip by its name on the timeline.
                HStack(spacing: 8) {
                    Button {
                        model.moveClip(segment.id, toIndex: index - 1)
                    } label: {
                        Label(L("Move earlier"), systemImage: "arrow.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(VideoSecondaryButtonStyle())
                    .disabled(index == 0)
                    Button {
                        model.moveClip(segment.id, toIndex: index + 1)
                    } label: {
                        Label(L("Move later"), systemImage: "arrow.right")
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
            VideoInspectorSection(L("Text")) {
                TextField(L("Text"), text: Binding(get: { overlay.text }, set: { value in model.updateOverlay(overlay.id, coalesce: "text-\(overlay.id)") { $0.text = value } }), axis: .vertical)
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
                    title: L("Size"),
                    value: Binding(get: { model.textSize(of: overlay) }, set: { model.setTextSize($0, of: overlay.id) }),
                    range: 14...64,
                    format: { "\(Int($0.rounded()))" },
                    onEditingEnded: { model.endGesture() }
                )
            }
        }
        if overlay.kind.hasColor {
            VideoInspectorSection(overlay.kind == .text ? L("Tag color") : L("Color")) {
                VideoOverlayColorPicker(model: model, overlay: overlay)
            }
        }
        if overlay.kind == .arrow || overlay.kind == .highlight {
            VideoInspectorSection(L("Thickness")) {
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
                Label(L("Turn around"), systemImage: "arrow.left.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VideoSecondaryButtonStyle())
            .help(L("Swap the arrow's head and tail"))
        }
        if overlay.kind == .spotlight {
            VideoInspectorSection(L("Shape")) {
                VideoSegmented(
                    options: VideoOverlayShape.allCases.map { ($0, $0.title) },
                    selection: Binding(get: { overlay.shape ?? .rectangle }, set: { model.setOverlayShape(overlay.id, $0) })
                )
            }
        }
        // Images have their own placement controls (VideoImageOverlays.swift).
        if overlay.kind != .image {
            VideoInspectorSection(L("Placement")) {
                Text(placementHelp(overlay.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(VideoEditorTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func placementHelp(_ kind: VideoDemoOverlayEffectKind) -> String {
        switch kind {
        case .blur: return L("Drag the box on the preview over anything private. Blur follows zooms and stays until its bar ends.")
        case .arrow: return L("Drag the arrow on the preview to move it; drag its head or tail to point it anywhere. Its bar on the timeline sets when it shows.")
        case .spotlight: return L("Drag the spot on the preview; drag a corner to resize it. Everything around it dims while its bar on the timeline runs.")
        case .text: return L("Drag it on the preview to move it; drag a corner to resize; double-click it to type. Its bar on the timeline sets when it shows.")
        default: return L("Drag it on the preview to move it; drag a corner to resize. Its bar on the timeline sets when it shows.")
        }
    }
}
