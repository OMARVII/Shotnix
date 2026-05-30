import AppKit
import Vision

struct QRCodeResult: Hashable {
    let payload: String
}

enum QRCodeEngine {

    static func detect(in image: NSImage) async -> [QRCodeResult] {
        guard let cgImage = image.bestCGImage else { return [] }
        return await detect(in: cgImage)
    }

    static func detect(in cgImage: CGImage) async -> [QRCodeResult] {
        await withCheckedContinuation { continuation in
            var didResume = false
            let request = VNDetectBarcodesRequest { request, error in
                guard !didResume else { return }
                didResume = true
                if error != nil {
                    continuation.resume(returning: [])
                    return
                }

                let observations = request.results as? [VNBarcodeObservation] ?? []
                let results = observations
                    .filter { $0.symbology == .qr }
                    .compactMap { observation -> QRCodeResult? in
                        guard let payload = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty else {
                            return nil
                        }
                        return QRCodeResult(payload: payload)
                    }

                var seen = Set<String>()
                let uniqueResults = results.filter { seen.insert($0.payload).inserted }
                continuation.resume(returning: uniqueResults)
            }
            request.symbologies = [.qr]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: [])
            }
        }
    }
}
