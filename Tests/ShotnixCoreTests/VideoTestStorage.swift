import Foundation
@testable import ShotnixCore

/// Points video drafts, recording metadata, and the export index at a
/// throwaway folder, so tests never write into the real Application Support.
enum VideoTestStorage {
    static func isolate() {
        guard VideoStorageLocation.overrideRoot == nil else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-test-storage", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VideoStorageLocation.overrideRoot = root
    }
}
