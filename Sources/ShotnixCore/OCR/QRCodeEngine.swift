import AppKit
import Vision

struct QRCodeResult: Hashable {
    let payload: String
    let symbology: VNBarcodeSymbology

    init(payload: String, symbology: VNBarcodeSymbology = .qr) {
        self.payload = payload
        self.symbology = symbology
    }

    var isQRCode: Bool { symbology == .qr }

    /// Human-readable name for the detected symbology (e.g. "QR Code", "Code 128", "EAN-13").
    var symbologyName: String {
        if #available(macOS 14.0, *), symbology == .msiPlessey {
            return "MSI Plessey"
        }
        switch symbology {
        case .qr: return "QR Code"
        case .microQR: return "Micro QR"
        case .aztec: return "Aztec"
        case .dataMatrix: return "Data Matrix"
        case .pdf417: return "PDF417"
        case .microPDF417: return "Micro PDF417"
        case .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum: return "Code 39"
        case .code93, .code93i: return "Code 93"
        case .code128: return "Code 128"
        case .ean8: return "EAN-8"
        case .ean13: return "EAN-13"
        case .upce: return "UPC-E"
        case .itf14: return "ITF-14"
        case .i2of5, .i2of5Checksum: return "Interleaved 2 of 5"
        case .codabar: return "Codabar"
        case .gs1DataBar, .gs1DataBarExpanded, .gs1DataBarLimited: return "GS1 DataBar"
        default: return "Barcode"
        }
    }
}

enum QRCodeEngine {

    /// Every barcode symbology Shotnix decodes — QR plus the common 1D retail,
    /// logistics, and 2D matrix codes.
    private static var supportedSymbologies: [VNBarcodeSymbology] {
        var symbologies: [VNBarcodeSymbology] = [
            .qr, .microQR, .aztec, .dataMatrix, .pdf417, .microPDF417,
            .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum,
            .code93, .code93i, .code128,
            .ean8, .ean13, .upce, .itf14, .i2of5, .i2of5Checksum,
            .codabar, .gs1DataBar, .gs1DataBarExpanded, .gs1DataBarLimited
        ]
        if #available(macOS 14.0, *) {
            symbologies.append(.msiPlessey)
        }
        return symbologies
    }

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
                    .compactMap { observation -> QRCodeResult? in
                        guard let payload = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty else {
                            return nil
                        }
                        return QRCodeResult(payload: payload, symbology: observation.symbology)
                    }

                var seen = Set<String>()
                let uniqueResults = results.filter { seen.insert($0.payload).inserted }
                continuation.resume(returning: uniqueResults)
            }
            request.symbologies = supportedSymbologies

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
