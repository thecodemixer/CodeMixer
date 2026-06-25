import AppKit
import CoreImage

/// Tiny wrapper around CoreImage QR generation.
///
/// Keeping this in `External/` confines CoreImage usage to one UI boundary and
/// makes the Remote settings view a plain projection of state.
struct QRCodeRenderer {
    private let context = CIContext()

    func image(for payload: String, size: CGFloat = 160) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator"),
              let data = payload.data(using: .utf8) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scale = size / max(output.extent.width, output.extent.height)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}
