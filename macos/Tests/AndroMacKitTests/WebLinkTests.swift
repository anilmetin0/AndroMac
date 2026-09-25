import Foundation
import Testing
@testable import AndroMacKit

struct WebLinkTests {

    @Test func findsTheFirstWebAddress() {
        #expect(WebLink.find(in: "See https://github.com/anilmetin0/AndroMac and https://example.com")?
            .absoluteString == "https://github.com/anilmetin0/AndroMac")
        #expect(WebLink.find(in: "Track it at example.com/p/42")?.host == "example.com")
    }

    @Test func offersNothingButTheWeb() {
        #expect(WebLink.find(in: "No link here, only 481920") == nil)
        #expect(WebLink.find(in: "Write to someone@example.com") == nil)
        #expect(WebLink.find(in: "file:///etc/passwd") == nil)
        #expect(WebLink.find(in: "") == nil)
        #expect(!WebLink.isWeb(URL(string: "javascript:alert(1)")!))
        #expect(!WebLink.isWeb(URL(string: "whatsapp://send?text=hi")!))
    }

    @Test func aShortenedLinkIsNotOffered() {
        // X's notification text: the address is cut off with an ellipsis.
        #expect(WebLink.find(in: "Claude FM 🎵 music x.com/i/broadcasts/1… live now") == nil)
        #expect(WebLink.find(in: "Read more at example.com/a/long/pa...") == nil)
        // A whole link after a cut one is still found.
        #expect(WebLink.find(in: "x.com/i/1… or https://example.com/full")?.absoluteString == "https://example.com/full")
        // A sentence that ends after a whole link keeps it.
        #expect(WebLink.find(in: "Details: https://example.com/p/42.")?.host == "example.com")
    }
}
