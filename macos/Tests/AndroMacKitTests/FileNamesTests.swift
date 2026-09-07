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
