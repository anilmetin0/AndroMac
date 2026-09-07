import Testing
@testable import AndroMacKit

struct VersionTests {

    @Test func parsesEveryFormThePipelineProduces() {
        #expect(AppVersion.find(in: "v1.0.0") == AppVersion(1, 0, 0))
        #expect(AppVersion.find(in: "Development build 1.0.1-dev.42") == AppVersion(1, 0, 1, dev: 42))
        #expect(AppVersion.find(in: "1.0.0 (12 · abc1234)") == AppVersion(1, 0, 0))
        #expect(AppVersion.find(in: "AndroMac-2.10.3-macOS.zip") == AppVersion(2, 10, 3))
    }

    @Test func rejectsWhatIsNotAVersion() {
        #expect(AppVersion.find(in: "dev") == nil)
        #expect(AppVersion.find(in: "1.0") == nil)
        #expect(AppVersion.find(in: "") == nil)
    }

    @Test func stableOutranksItsOwnDevBuilds() {
        #expect(AppVersion(1, 0, 1, dev: 99) < AppVersion(1, 0, 1))
        #expect(AppVersion(1, 0, 0) < AppVersion(1, 0, 1, dev: 1))
        #expect(AppVersion(1, 0, 1, dev: 1) < AppVersion(1, 0, 1, dev: 2))
        #expect(AppVersion(1, 9, 9) < AppVersion(2, 0, 0))
        #expect(AppVersion(1, 0, 10) > AppVersion(1, 0, 9))
    }

    @Test func roundTripsThroughDescription() {
        for text in ["1.0.0", "1.0.1-dev.42", "12.34.56"] {
            #expect(AppVersion.find(in: text)?.description == text)
        }
    }
}
