import SwiftUI
import UIKit
import ImageIO

// MARK: - GIF decoder

/// Decodes raw data into a UIImage.
/// For multi-frame GIFs, returns an animated UIImage with correct per-frame timing.
/// For static images (PNG, JPEG, single-frame GIF), returns a plain UIImage.
func decodeGIF(_ data: Data) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let count = CGImageSourceGetCount(source)
    guard count > 1 else { return UIImage(data: data) }

    var frames: [UIImage] = []
    var totalDuration: Double = 0

    for i in 0..<count {
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
        frames.append(UIImage(cgImage: cgImage))

        let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
        let gifProps = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        // Prefer unclamped delay; fall back to clamped; minimum 20 ms to avoid degenerate zero-delay GIFs
        let delay = (gifProps?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                 ?? (gifProps?[kCGImagePropertyGIFDelayTime] as? Double)
                 ?? 0.1
        totalDuration += max(delay, 0.02)
    }

    guard !frames.isEmpty else { return UIImage(data: data) }
    return UIImage.animatedImage(with: frames, duration: totalDuration)
}

// MARK: - SwiftUI wrapper

/// SwiftUI view that renders a UIImage, including animated UIImages (GIFs).
/// Respects SwiftUI layout — size the view with .frame() from the call site.
struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        // Allow SwiftUI to drive the frame
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.image = image
    }
}
