import AVFoundation

/// The microphone during a recording. Its capture session starts and stops
/// off the main thread (startRunning blocks for a noticeable moment) and
/// delivers one fixed PCM format, so a device switch mid-recording never
/// changes what the writer gets. When the device disappears it moves to
/// the new system default; with no microphone left it waits for one.
@MainActor
final class RecordingMicrophone {
    enum Event: Equatable {
        /// Now recording from this device (by name).
        case switched(String)
        /// No microphone left; the recording continues without one.
        case lost
        /// The session stopped with an error it couldn't recover from.
        case failed
    }

    /// Float mono at 48 kHz, whatever the device's own format.
    static let sampleSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    private let sessionQueue = DispatchQueue(label: "com.shotnix.recording.microphone", qos: .userInitiated)
    private let sampleQueue: DispatchQueue
    private let delegate: AVCaptureAudioDataOutputSampleBufferDelegate
    private var session: AVCaptureSession?
    private var sessionObservers: [NSObjectProtocol] = []
    private var deviceObservers: [NSObjectProtocol] = []
    private var didRetryAfterError = false
    private(set) var device: AVCaptureDevice?
    var eventHandler: ((Event) -> Void)?

    init(delegate: AVCaptureAudioDataOutputSampleBufferDelegate, sampleQueue: DispatchQueue) {
        self.delegate = delegate
        self.sampleQueue = sampleQueue
    }

    /// The chosen device when it's connected, else the system default.
    static func device(for id: String) -> AVCaptureDevice? {
        if !id.isEmpty, let device = AVCaptureDevice(uniqueID: id), device.isConnected {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }

    /// The system default — or, while the default still names the device
    /// that just vanished, any other connected microphone.
    private static func replacement(excluding lostID: String?) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.microphone, .externalUnknown]
        } else {
            types = [.builtInMicrophone, .externalUnknown]
        }
        let others = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
        return ([AVCaptureDevice.default(for: .audio)].compactMap { $0 } + others)
            .first { $0.uniqueID != lostID && $0.isConnected }
    }

    /// Builds the session (not running yet); throws when the device can't open.
    func prepare(device: AVCaptureDevice) throws {
        let session = try Self.makeSession(device: device, delegate: delegate, queue: sampleQueue)
        self.session = session
        self.device = device
        observe(session: session)
        observeDevices()
    }

    func start() async {
        guard let session else { return }
        await run(session) { $0.startRunning() }
    }

    func stop() {
        (sessionObservers + deviceObservers).forEach(NotificationCenter.default.removeObserver)
        sessionObservers.removeAll()
        deviceObservers.removeAll()
        eventHandler = nil
        guard let session else { return }
        self.session = nil
        device = nil
        nonisolated(unsafe) let stopping = session
        sessionQueue.async { stopping.stopRunning() }
    }

    private static func makeSession(device: AVCaptureDevice, delegate: AVCaptureAudioDataOutputSampleBufferDelegate, queue: DispatchQueue) throws -> AVCaptureSession {
        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecordingMicrophoneError.cannotAddInput }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = sampleSettings
        output.setSampleBufferDelegate(delegate, queue: queue)
        guard session.canAddOutput(output) else { throw RecordingMicrophoneError.cannotAddInput }
        session.addOutput(output)
        session.commitConfiguration()
        return session
    }

    private func run(_ session: AVCaptureSession, _ work: @escaping @Sendable (AVCaptureSession) -> Void) async {
        nonisolated(unsafe) let target = session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                work(target)
                continuation.resume()
            }
        }
    }

    private func observe(session: AVCaptureSession) {
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers = [
            NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                MainActor.assumeIsolated { self?.sessionFailed(error) }
            },
        ]
    }

    private func observeDevices() {
        guard deviceObservers.isEmpty else { return }
        deviceObservers = [
            NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] notification in
                let gone = notification.object as? AVCaptureDevice
                MainActor.assumeIsolated { self?.deviceDisconnected(gone) }
            },
            NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] notification in
                let added = notification.object as? AVCaptureDevice
                MainActor.assumeIsolated { self?.deviceConnected(added) }
            },
        ]
    }

    private func deviceDisconnected(_ gone: AVCaptureDevice?) {
        guard let gone, let device, gone.uniqueID == device.uniqueID else { return }
        switchToDefault(excluding: gone.uniqueID)
    }

    private func deviceConnected(_ added: AVCaptureDevice?) {
        // Only while waiting: a working microphone is never swapped out.
        guard device == nil, let added, added.hasMediaType(.audio) else { return }
        switchToDefault(excluding: nil)
    }

    private func sessionFailed(_ error: NSError?) {
        print("[Shotnix] Microphone session error: \(error.map { "\($0)" } ?? "unknown")")
        guard let session else { return }
        if let device, !device.isConnected {
            switchToDefault(excluding: device.uniqueID)
        } else if !didRetryAfterError {
            // One restart covers the common transient errors (the audio
            // system resetting, another app briefly grabbing the device).
            didRetryAfterError = true
            Task { await run(session) { $0.startRunning() } }
        } else {
            eventHandler?(.failed)
        }
    }

    private func switchToDefault(excluding lostID: String?) {
        if let old = session {
            nonisolated(unsafe) let stopping = old
            sessionQueue.async { stopping.stopRunning() }
        }
        session = nil
        device = nil
        guard let next = Self.replacement(excluding: lostID) else {
            eventHandler?(.lost)
            return
        }
        do {
            let session = try Self.makeSession(device: next, delegate: delegate, queue: sampleQueue)
            self.session = session
            device = next
            didRetryAfterError = false
            observe(session: session)
            Task { await run(session) { $0.startRunning() } }
            eventHandler?(.switched(next.localizedName))
        } catch {
            print("[Shotnix] Microphone switch failed: \(error)")
            eventHandler?(.lost)
        }
    }
}

enum RecordingMicrophoneError: Error {
    case cannotAddInput
}
