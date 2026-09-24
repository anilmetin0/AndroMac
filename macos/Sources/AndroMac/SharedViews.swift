import AppKit
import CoreImage.CIFilterBuiltins
import ImageIO
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
///
/// Laid over the list, which stays in place even when empty. A detail page with no scroll view
/// changes how the window lays out its toolbar on macOS 26+ (the sidebar moved by 28 pt whenever an
/// empty list opened), and swapping the list for another view while a confirmation sheet closes
/// threw AppKit's "too many Update Constraints passes" exception: the crash on Clear.
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
        .allowsHitTesting(false)
    }
}

extension View {
    func emptyState(_ isEmpty: Bool, symbol: String, message: @autoclosure () -> String) -> some View {
        overlay { if isEmpty { EmptyState(symbol: symbol, message: message()) } }
    }
}

/// Opens the web address a notification carries, in the default browser. The address is in the
/// tooltip, so what opens is visible before the click.
struct OpenLinkButton: View {
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Image(systemName: "arrow.up.right.square")
        }
        .buttonStyle(.borderless)
        .help(url.absoluteString)
        .accessibilityLabel(Text("Open link"))
    }
}

/// "7 min. ago", redrawn once a minute, with the full date and time on hover.
///
/// `Text(date, style: .relative)` ticks every second ("7 min, 3 sec") and kept redrawing the panel;
/// a minute is as fine as this needs to be.
struct RelativeTime: View {
    let date: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(Self.string(date, now: context.date))
        }
        .help(date.formatted(date: .abbreviated, time: .shortened))
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        f.unitsStyle = .short
        return f
    }()

    /// Under a minute reads "now": the view redraws once a minute, so "20 sec. ago" would stand still.
    static func string(_ date: Date, now: Date = Date()) -> String {
        formatter.localizedString(for: now.timeIntervalSince(date) < 60 ? now : date, relativeTo: now)
    }
}

/// The phone's own app icon, cut like a Mac app icon; an initial-letter badge when there is none.
struct AppIcon: View {
    let pkg: String
    let fallback: String
    var size: CGFloat = 20
    /// Redraws when the phone's icon arrives, instead of at the next unrelated change.
    @ObservedObject private var icons = IconCache.shared

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
    }

    var body: some View {
        if let image = icons.image(for: pkg) ?? DemoMode.icon(for: pkg) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(shape)
        } else {
            shape
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

/// The picture a notification carried (a photo in a chat, a big picture), as a thumbnail.
///
/// The frame is fixed before anything loads, so the row never moves when the picture arrives. The
/// file is decoded off the main thread straight to the size it is drawn at, and kept in memory:
/// the panel redraws often and must not decode a photo each time.
struct NotificationPicture: View {
    let entry: NotificationHistory.Entry
    let size: CGFloat

    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?

    /// The picture alone, no plate behind it: an avatar the phone already cut round stays round,
    /// instead of sitting on a grey square.
    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: scale)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        .task(id: entry.id) { image = await Self.load(entry, pixels: size * scale) }
        .accessibilityHidden(true)
    }

    @MainActor private static let cache = NSCache<NSString, CGImage>()

    @MainActor
    private static func load(_ entry: NotificationHistory.Entry, pixels: CGFloat) async -> CGImage? {
        guard let name = entry.image else { return nil }
        let key = "\(name)@\(Int(pixels))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image: CGImage?
        if DemoMode.isOn {
            image = DemoMode.picture(named: name)
        } else if let data = NotificationHistory.shared.imageData(for: entry) {
            // Twice the edge: the longer side is what the limit bounds, and a fill crops to the shorter.
            image = await Task.detached { thumbnail(data, maxPixels: pixels * 2) }.value
        } else {
            image = nil
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private nonisolated static func thumbnail(_ data: Data, maxPixels: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
