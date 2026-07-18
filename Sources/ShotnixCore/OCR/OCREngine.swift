import Vision
import AppKit

enum OCREngineError: Error {
    case invalidImage
}

enum OCREngine {

    /// Recognize text in an NSImage and return the full recognized string.
    /// Returns an empty string when the region genuinely contains no text;
    /// throws when the image is unusable or Vision recognition fails.
    static func recognizeText(in image: NSImage) async throws -> String {
        guard let cgImage = image.bestCGImage else { throw OCREngineError.invalidImage }
        return try await recognizeText(in: cgImage)
    }

    static func recognizeText(in cgImage: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            let request = VNRecognizeTextRequest { request, error in
                guard !didResume else { return }
                didResume = true
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                guard !didResume else { return }
                didResume = true
                continuation.resume(throwing: error)
            }
        }
    }
}
