import Foundation
import Testing
@testable import AndroMacKit

/// Most cases come from AOSP's `NotificationOtpDetectionHelperTest`, the suite of the detector
/// this is a port of; they are prefixed with a context word here, since this port always needs one.
struct VerificationCodeTests {

    private func code(_ text: String) -> String? { VerificationCode.find(in: text) }

    // MARK: what should be offered

    @Test func findsACodeAnnouncedByAContextWord() {
        #expect(code("Your verification code is 481920") == "481920")
        #expect(code("G-728301 is your Google code") == "728301")
        #expect(code("OTP 1234 expires in 5 minutes") == "1234")
        #expect(code("Use 90210 to sign in") == "90210")
        #expect(code("Your code 8821, valid until 1830") == "8821")
    }

    @Test func turkishContextWordsWithTheirSuffixes() {
        #expect(code("Doğrulama kodunuz: 4821") == "4821")
        #expect(code("Tek kullanımlık şifreniz 90210") == "90210")
        #expect(code("DOGRULAMA KODU 553311") == "553311")
        #expect(code("Güvenlik kodu 8842") == "8842")
        #expect(code("ŞİFRENİZ: 774411") == "774411")
        #expect(code("Giriş için 5521 kodunu kullanın") == "5521")
    }

    @Test func lengthsAndShapes() {
        #expect(code("code 1235") == "1235")
        #expect(code("code 123G5") == "123G5")
        #expect(code("code 123456F8") == "123456F8")
        #expect(code("code 123 456") == "123456")
        #expect(code("code G-FD-745") == "G-FD-745")
        #expect(code("code g4zy75") == "g4zy75")
        #expect(code("code 123") == nil)
        #expect(code("code 123G") == nil)
        #expect(code("code 123T56789") == nil)
        #expect(code("code 12 345") == nil)
        #expect(code("code TEFHXES") == nil)
        #expect(code("code 6--7893") == nil)
        #expect(code("code 123码456") == nil)
    }

    @Test func boundariesAroundTheCode() {
        #expect(code("your code is:G-345821") == "345821")
        #expect(code("your code is \nG-345821") == "345821")
        #expect(code("your code is 'G-345821'") == "345821")
        #expect(code("your code is [G-345821]") == "345821")
        #expect(code("you code is G-345821.") == "345821")
        #expect(code("your code isG-345821") == nil)
        #expect(code("your code is G-345821for real") == nil)
        #expect(code("your code is 4 G-345821") == nil)
        #expect(code("your code is G-345821$") == nil)
        #expect(code("you code is 'G-345821_'") == nil)
        #expect(code("your code is4:G-345821") == nil)
    }

    @Test func datesAndPhoneNumbersAreNotCodes() {
        #expect(code("code 01-01-2001") == nil)
        #expect(code("code 1-1-01") == nil)
        #expect(code("code (888) 888-8888") == nil)
        #expect(code("code 888-888-8888") == nil)
        #expect(code("1-1-01 is the date of your code T3425") == "T3425")
        #expect(code("code 34-58-30") == "34-58-30")
        #expect(code("code 888-777-6666 then code 1543 code") == "1543")
    }

    @Test func threeLowercaseLettersAreNotACode() {
        #expect(code("code 34agb") == nil)
    }

    // MARK: context

    @Test func contextWordsAreWholeWords() {
        #expect(code("login This is a false positive 4543") == "4543")
        #expect(code("LoGiN This is a false positive 4543") == "4543")
        #expect(code("two-factor This is a false positive 4543") == "4543")
        #expect(code("pins This is a false positive 4543") == nil)
        #expect(code("gaping This is a false positive 4543") == nil)
        #expect(code("backspin This is a false positive 4543") == nil)
        #expect(code("This is a false positive 4543") == nil)
    }

    @Test func contextMustBeCloseAndInTheRightSentence() {
        #expect(code("context word: code. This sentence has the actual value of 434343") == "434343")
        #expect(code("your code is \n 34343") == "34343")
        #expect(code("context word: code. One sentence. actual value 34343") == nil)
        #expect(code("34343 is a number. This number is a code") == nil)
        #expect(code("context word: code. \(String(repeating: "f", count: 60)) value of 434343") == nil)
        #expect(code("34343 \(String(repeating: "f", count: 60)) code") == nil)
    }

    // MARK: what must stay silent

    @Test func ordinaryMessagesOfferNothing() {
        #expect(code("DEDİKONDU (6 mesaj): Sülo · çıkmaz") == nil)
        #expect(code("AI · AIS Field, Milvus Robotics ve diğer şirketler") == nil)
        #expect(code("See you in 2026") == nil)
        #expect(code("Flight 1234 departs 5678") == nil)
        #expect(code("Siparişiniz 482913 onaylandı") == nil)
        #expect(code("483927") == nil)
        #expect(code("") == nil)
    }
}
