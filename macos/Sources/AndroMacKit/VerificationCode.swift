import Foundation

/// Finds the one-time code inside a notification, so the panel and the banner can offer to copy
/// just that.
///
/// The job this solves: a bank or a login sends "Your verification code is 481920", and the user
/// reads six digits off the Mac screen and types them somewhere else. The code is already on the
/// Mac — it should be one click, not a transcription.
///
/// The rules are Android's own: a port of AOSP `NotificationOtpDetectionHelper` (ExtServices,
/// Apache 2.0), the detector Android 15 uses to hide codes from untrusted listeners. Its shape
/// regex, its date and phone-number false positives and its context rule are kept as they are;
/// its English context words gain Turkish ones. Where AOSP falls back to "any code-shaped run"
/// when it cannot tell the language, this always takes the language path: a candidate counts only
/// with a context word near it. A copy button on the wrong notification is worse than none.
public enum VerificationCode {

    // MARK: shape (AOSP, with [0-9] for \d: ICU's \d also takes Arabic-Indic and other digits)

    /// Line start, or after an opening bracket, quote, `=`, `>`, an ideograph, a colon not after a
    /// digit, or a space not after a digit. Not consumed.
    private static let start = #"(^|(?<=((^|[^0-9])\s)|[>("'=\[\p{Ideographic}]|[^0-9]:))"#
    /// A digit or a letter that is not an ideograph.
    private static let otpChar = #"([[0-9\p{Alphabetic}]&&[^\p{Ideographic}]])"#
    private static let otpCharWithDash = "(\(otpChar)-?)"
    /// At least one digit within the run.
    private static let findDigit = "(?=\(otpCharWithDash){0,7}[0-9])"
    /// 5 to 8 characters, dashes allowed between them, not after the last.
    private static let otpChars = "(\(otpCharWithDash){4,7}\(otpChar))"
    /// Line end, a space not before a digit, an ideograph, or closing punctuation. Not consumed.
    private static let end = #"(?=\s[^0-9]|$|\p{Ideographic}|[.?!,)'\]"])"#
    private static let fourDigits = "([0-9]{4})"
    private static let sixDigitsWithSpace = #"([0-9]{3}\s[0-9]{3})"#

    private static let allOTP =
        "\(start)((\(findDigit)\(otpChars))|\(fourDigits)|\(sixDigitsWithSpace))\(end)"

    /// Dates with dashes and ten-digit phone numbers look like codes and are not.
    private static let dateWithDashes = "([0-3]?[0-9]-[0-3]?[0-9]-([12][0-9])?[0-9][0-9])"
    private static let phoneWithSpace = #"(\(?[0-9]{3}\)?(-|\s)?[0-9]{3}(-|\s)?[0-9]{4})"#
    /// No known code has three lowercase letters in a row ("34agb").
    private static let threeLowercase = #"\p{Ll}{3}"#

    // MARK: context

    /// Words that make a nearby run a code. English is AOSP's list plus "sign in"; the Turkish ones
    /// take any suffix ("kodunuz", "şifreniz"), and spell out İ/ı, which case folding does not
    /// pair with i.
    private static let contextWords = [
        #"pin"#, #"pass[-\s]?(code|word)"#, #"TAN"#, #"otp"#, #"2fa"#, #"(two|2)[-\s]?factor"#,
        #"log[-\s]?in"#, #"sign[-\s]?in"#, #"auth(enticat(e|ion))?"#, #"code"#, #"secret"#,
        #"verif(y|ication)"#, #"one(\s|-)?time"#, #"access"#, #"validat(e|ion)"#,
        #"kod\w*"#, #"[şs][iİı]fre\w*"#, #"parola\w*"#, #"do[ğg]rulama\w*"#,
        #"tek\s?kullan[iİı]ml[iİı]k"#, #"g[iİı]r[iİı][şs]\w*"#, #"g[üu]venl[iİı]k\w*"#,
    ]

    /// AOSP reads at most this much of a notification.
    private static let maxLength = 600
    /// How far a context word may sit from the code, in characters.
    private static let reach = 50

    private static let options: NSRegularExpression.Options =
        [.caseInsensitive, .dotMatchesLineSeparators, .anchorsMatchLines]
    // Patterns are constants, so a failure is a programming error the tests catch at once.
    // swiftlint:disable force_try
    private static let otpRegex = try! NSRegularExpression(pattern: allOTP, options: options)
    private static let falsePositiveRegex = try! NSRegularExpression(
        pattern: "\(start)(\(dateWithDashes)|\(phoneWithSpace))\(end)", options: options)
    private static let lowercaseRegex = try! NSRegularExpression(pattern: threeLowercase)
    private static let contextRegex = try! NSRegularExpression(
        pattern: #"\b("# + contextWords.joined(separator: "|") + #")\b"#, options: options)
    // swiftlint:enable force_try

    /// The code in this text, or `nil` when there is nothing worth offering.
    public static func find(in text: String) -> String? {
        let text = String(text.prefix(maxLength))
        let whole = NSRange(text.startIndex..., in: text)
        let ns = text as NSString

        let falsePositives = falsePositiveRegex.matches(in: text, range: whole).map(\.range)
        let words = contextRegex.matches(in: text, range: whole).map(\.range)
        guard !words.isEmpty else { return nil }

        for match in otpRegex.matches(in: text, range: whole) {
            let range = match.range
            let candidate = ns.substring(with: range)
            // Inside a date or a phone number: that is what it is.
            if falsePositives.contains(where: { NSIntersectionRange($0, range).length == range.length }) { continue }
            if lowercaseRegex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil { continue }
            if words.contains(where: { near($0, range, in: ns) }) { return normalized(candidate) }
        }
        return nil
    }

    /// AOSP's rule: the word before the code, at most `reach` characters away, in the same or the
    /// previous sentence; or after it, at most `reach` away, in the same sentence.
    private static func near(_ word: NSRange, _ code: NSRange, in text: NSString) -> Bool {
        let sentenceEnds = CharacterSet(charactersIn: ".?!")
        if NSMaxRange(word) <= code.location {
            let gap = code.location - NSMaxRange(word)
            guard gap >= 1, gap <= reach else { return false }
            let between = text.substring(with: NSRange(location: NSMaxRange(word), length: gap))
            return between.unicodeScalars.filter(sentenceEnds.contains).count <= 1
        }
        if NSMaxRange(code) <= word.location {
            let gap = word.location - NSMaxRange(code)
            guard gap >= 1, gap <= reach else { return false }
            let between = text.substring(with: NSRange(location: NSMaxRange(code), length: gap))
            return !between.unicodeScalars.contains(where: sentenceEnds.contains)
        }
        return false
    }

    /// What gets typed: "123 456" is 123456, and Google's "G-728301" is 728301. A code that mixes
    /// letters and dashes otherwise ("G-FD-745") is copied as shown.
    private static func normalized(_ code: String) -> String {
        let compact = code.filter { !$0.isWhitespace }
        if let dash = compact.lastIndex(of: "-") {
            let prefix = compact[..<dash], digits = compact[compact.index(after: dash)...]
            if !prefix.isEmpty, prefix.allSatisfy({ $0.isLetter && $0.isASCII }),
               digits.count >= 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return String(digits)
            }
        }
        return compact
    }
}
