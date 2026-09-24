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
}
