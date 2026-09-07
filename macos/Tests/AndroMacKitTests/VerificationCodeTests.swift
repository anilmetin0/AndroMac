import Foundation
import Testing
@testable import AndroMacKit

struct VerificationCodeTests {

    // MARK: what should be offered

    @Test func findsACodeAnnouncedByAKeyword() {
        #expect(VerificationCode.find(in: "Your verification code is 481920") == "481920")
        #expect(VerificationCode.find(in: "G-728301 is your Google code") == "728301")
        #expect(VerificationCode.find(in: "Doğrulama kodunuz: 4821") == "4821")
        #expect(VerificationCode.find(in: "Tek kullanımlık şifreniz 90210") == "90210")
        #expect(VerificationCode.find(in: "OTP 1234 expires in 5 minutes") == "1234")
    }

    @Test func keywordMatchIgnoresCaseAndTurkishDiacritics() {
        #expect(VerificationCode.find(in: "DOGRULAMA KODU 553311") == "553311")
        #expect(VerificationCode.find(in: "Güvenlik kodu 8842") == "8842")
    }

    @Test func findsALoneLongNumberEvenWithoutAKeyword() {
        #expect(VerificationCode.find(in: "483927") == "483927")
        #expect(VerificationCode.find(in: "Use 90210 to sign in") == "90210")
    }

    // MARK: what must stay silent

    @Test func ignoresOrdinaryMessages() {
        #expect(VerificationCode.find(in: "DEDİKONDU (6 mesaj): Sülo · çıkmaz") == nil)
        #expect(VerificationCode.find(in: "AI · AIS Field, Milvus Robotics ve diğer şirketler") == nil)
        #expect(VerificationCode.find(in: "Are you coming?") == nil)
        #expect(VerificationCode.find(in: "") == nil)
    }

    @Test func aFourDigitNumberAloneIsNotEnoughWithoutAKeyword() {
        // A year, a room number, a jersey. Too likely to be wrong to earn a button.
        #expect(VerificationCode.find(in: "See you in 2026") == nil)
    }

    @Test func severalNumbersWithoutAKeywordAreAmbiguousSoNothingIsOffered() {
        #expect(VerificationCode.find(in: "Flight 1234 departs 5678") == nil)
    }

    @Test func digitsGluedToLettersAreNotCodes() {
        #expect(VerificationCode.find(in: "Order AB1234XY shipped") == nil)
        #expect(VerificationCode.find(in: "Build 12345abc finished") == nil)
    }

    @Test func runsOutsideFourToEightDigitsAreIgnored() {
        #expect(VerificationCode.find(in: "Only 123 left") == nil)                  // too short
        #expect(VerificationCode.find(in: "Card 1234567890123456") == nil)          // too long
    }

    @Test func aKeywordPicksTheFirstCandidateRatherThanGivingUp() {
        // With a keyword present the message is code-shaped, so ambiguity resolves to the first run
        // instead of returning nothing — "code 8821, valid 10 minutes" must still offer 8821.
        #expect(VerificationCode.find(in: "Your code 8821, valid until 1830") == "8821")
    }
}
