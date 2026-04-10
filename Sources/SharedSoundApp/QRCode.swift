import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Tiny CoreImage QR generator. Lets host guests scan the web URL with
/// their phone instead of typing a 192.168.x.y address.
enum QRCode {
    static func image(for string: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Upscale so it renders crisp — CoreImage emits tiny bitmaps.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))

        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        #if os(macOS)
        let nsImage = NSImage(cgImage: cg, size: .zero)
        return Image(nsImage: nsImage)
        #else
        return Image(uiImage: UIImage(cgImage: cg))
        #endif
    }
}
