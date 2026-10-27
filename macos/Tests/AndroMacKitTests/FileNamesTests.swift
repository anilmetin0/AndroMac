import Testing
@testable import AndroMacKit

struct FileNamesTests {

    @Test func keepsOnlyTheLastPathComponent() {
        #expect(FileNames.sanitize("../../etc/passwd") == "passwd")
        #expect(FileNames.sanitize("C:\\x\\y.txt") == "y.txt")
        #expect(FileNames.sanitize("/tmp/photo.jpg") == "photo.jpg")
    }

    @Test func dropsControlCharacters() {
        #expect(FileNames.sanitize("a\u{00}b\nc\u{7F}.txt") == "abc.txt")
    }

    @Test func dropsBidiOverridesAndZeroWidthCharacters() {
        // Would read as "Invoicednammoc.pdf" with the override left in.
        #expect(FileNames.sanitize("Invoice\u{202E}fdp.command") == "Invoicefdp.command")
        #expect(FileNames.sanitize("a\u{200B}b\u{2066}.txt\u{2069}") == "ab.txt")
        #expect(FileNames.sanitize("résumé.pdf") == "résumé.pdf")
        #expect(FileNames.sanitize("👩‍👩‍👧.png") == "👩👩👧.png")      // ZWJ is Cf too; the emoji stay
    }

    @Test func fallsBackWhenNothingIsLeft() {
        #expect(FileNames.sanitize("") == "file")
        #expect(FileNames.sanitize(".") == "file")
        #expect(FileNames.sanitize("..") == "file")
        #expect(FileNames.sanitize(" ...  ") == "file")
        #expect(FileNames.sanitize("/") == "file")
        #expect(FileNames.sanitize(".hidden") == "hidden")
        #expect(FileNames.sanitize("  spaced.txt") == "spaced.txt")
    }

    @Test func capsLongNamesAndKeepsTheExtension() {
        let long = String(repeating: "a", count: 300) + ".jpg"
        let out = FileNames.sanitize(long)
        #expect(out.utf8.count == 255)
        #expect(out.hasSuffix(".jpg"))

        // Multi-byte characters are cut on a character boundary, never in the middle of a scalar.
        let turkish = String(repeating: "ş", count: 200) + ".png"
        let cut = FileNames.sanitize(turkish)
        #expect(cut.utf8.count <= 255)
        #expect(cut.hasSuffix(".png"))
        #expect(cut.dropLast(4).allSatisfy { $0 == "ş" })
    }

    @Test func partNameFitsInOnePathComponent() {
        #expect(FileNames.partName("photo.jpg", tag: "abcd1234") == ".photo.jpg.abcd1234.part")

        // A sanitized name may use all 255 bytes; the temp name around it must still fit.
        for count in [240, 241, 255] {
            let base = String(repeating: "a", count: count - 4) + ".jpg"
            let part = FileNames.partName(base, tag: "abcd1234")
            #expect(part.utf8.count <= FileNames.maxBytes)
            #expect(part.hasPrefix(".a") && part.hasSuffix(".abcd1234.part"))
        }

        // Cut on a character boundary: no replacement character from a split scalar.
        let turkish = FileNames.sanitize(String(repeating: "ş", count: 200) + ".png")
        let part = FileNames.partName(turkish, tag: "abcd1234")
        #expect(part.utf8.count <= FileNames.maxBytes)
        #expect(!part.contains("\u{FFFD}"))
    }

    @Test func collisionSuffixGoesBeforeTheExtension() {
        var taken: Set<String> = ["photo.jpg", "photo (2).jpg"]
        #expect(FileNames.unique("photo.jpg") { taken.contains($0) } == "photo (3).jpg")
        #expect(FileNames.unique("new.jpg") { taken.contains($0) } == "new.jpg")
        taken.insert("README")
        #expect(FileNames.unique("README") { taken.contains($0) } == "README (2)")
    }

    @Test func chunkCount() {
        #expect(FileTransferMath.chunkCount(size: 0) == 0)
        #expect(FileTransferMath.chunkCount(size: 524_288) == 1)
        #expect(FileTransferMath.chunkCount(size: 524_289) == 2)
        #expect(FileTransferMath.chunkCount(size: 1) == 1)
    }
}
