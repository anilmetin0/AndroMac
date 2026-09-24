import Foundation

/// The first web address in a notification, for an Open link button on the Mac.
///
/// Only http and https: text from the phone never gets to open a file, a mail draft or another
/// app's URL scheme. A bare "github.com/…" counts, as a link detector reads it, and opens as http.
public enum WebLink {

    public static func find(in text: String) -> URL? {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).lazy.compactMap(\.url).first(where: isWeb)
    }

    /// An http or https URL with a host: the only kind the Mac opens on the phone's word.
    public static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host?.isEmpty == false
    }
}
