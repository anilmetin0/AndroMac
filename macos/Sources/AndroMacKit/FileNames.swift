import Foundation

/// File names that arrive over the wire are untrusted (docs/PROTOCOL.md §5, receiver rules).
/// Pure functions, so they can be tested without a socket.
public enum FileNames {

    /// The file system limit on one path component.
    public static let maxBytes = 255

    /// Last path component only, no control characters, no leading dots or whitespace, at most
    /// 255 bytes of UTF-8 (the stem is cut, the extension is kept). `file` when nothing is left.
    public static func sanitize(_ raw: String) -> String {
        var name = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        name.removeAll { c in c.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } }
        name = String(name.drop { $0 == "." || $0.isWhitespace })
        if name.utf8.count > maxBytes {
            let (stem, ext) = splitExtension(name)
            let cutStem = cut(stem, to: maxBytes - ext.utf8.count)
            name = cutStem.isEmpty ? cut(name, to: maxBytes) : cutStem + ext
        }
        return name.isEmpty ? "file" : name
    }

    /// `photo.jpg` → `photo (2).jpg`, `photo (3).jpg`, … until `exists` says no.
    public static func unique(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let (stem, ext) = splitExtension(name)
        // Leave room for the suffix so a name that already used the full 255 bytes still fits.
        let base = cut(stem, to: maxBytes - ext.utf8.count - 8)
        for n in 2...9999 {
            let candidate = "\(base) (\(n))\(ext)"
            if !exists(candidate) { return candidate }
        }
        return "\(base) (\(UUID().uuidString.prefix(8)))\(ext)"
    }

    /// `("photo", ".jpg")`; a name without a dot has an empty extension.
    static func splitExtension(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// Truncates on a character boundary so no scalar is split in half.
    private static func cut(_ text: String, to bytes: Int) -> String {
        var out = ""
        for c in text {
            if out.utf8.count + c.utf8.count > bytes { break }
            out.append(c)
        }
        return out
    }
}

/// The numbers of PROTOCOL §5: 512 KiB chunks, files up to 4 GiB.
public enum FileTransferMath {

    public static let chunkSize = 524_288
    public static let maxFileSize: Int64 = 4 << 30

    /// How many `file_chunk` messages a file of `size` bytes takes; `0` for an empty file.
    public static func chunkCount(size: Int64) -> Int {
        Int((size + Int64(chunkSize) - 1) / Int64(chunkSize))
    }
}
