import UIKit
import InkStudyCore

enum PigmentRenderer {
    static func cgImage(_ surface: PigmentSurface) -> CGImage? {
        let data = Data(surface.rgba) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: surface.width, height: surface.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: surface.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    @MainActor static func image(_ surface: PigmentSurface) -> UIImage {
        cgImage(surface).map { UIImage(cgImage: $0) } ?? UIImage()
    }
}
