import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - shared

/// A QR code for a URL, drawn from CoreImage — no dependency, nothing fetched.
///
/// Always dark-on-light, even in dark mode, and on its own light plate: an inverted QR is out of
/// spec and some phone cameras refuse it. `.interpolation(.none)` keeps the modules as hard squares
/// instead of blurring them, which is what makes a small code scannable at all.
struct QRCode: View {
    private let image: CGImage?
    private let size: CGFloat

    /// Rendered once per view identity — the URL never changes while the view is on screen.
    ///
    /// `maxSize` is a ceiling, not a target. The code is drawn at the largest whole number of
    /// pixels per module that fits and then shown at exactly that size, so one module is always the
    /// same number of pixels as every other. Stretching to fill the ceiling instead would leave
    /// some modules a pixel wider than their neighbours, which is what makes a small QR fail to
    /// scan on a phone held at an angle.
    init(_ url: URL, maxSize: CGFloat = 116) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"          // 15% recovery: enough for a screen, keeps modules big
        if let output = filter.outputImage {
            let scale = max((maxSize / output.extent.width).rounded(.down), 1)
            let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let rendered = CIContext().createCGImage(scaled, from: scaled.extent)
            image = rendered
            size = rendered.map { CGFloat($0.width) } ?? maxSize
        } else {
            image = nil
            size = maxSize
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: size, height: size)
            } else {
                // CoreImage does not fail here in practice; if it ever does, do not draw a hole.
                RoundedRectangle(cornerRadius: Theme.Radius.small)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: size, height: size)
            }
        }
        .padding(8)
        .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
    }
}

/// Empty state: it says what to do, not what is missing.
struct EmptyState: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The cached app icon; an initial-letter badge when there is none.
struct AppIcon: View {
    let pkg: String
    let fallback: String
    var size: CGFloat = 20

    var body: some View {
        if let image = IconCache.shared.image(for: pkg) {
            Image(nsImage: image)
                .resizable()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: size, height: size)
                .overlay(
                    Text(fallback.prefix(1).uppercased())
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
        }
    }
}
