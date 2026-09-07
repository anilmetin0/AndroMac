import Foundation

/// Finds the one-time code inside a notification, so the panel can offer to copy just that.
///
/// The job this solves: a bank or a login sends "Your verification code is 481920", and the user
/// reads six digits off the Mac screen and types them somewhere else. The code is already on the
/// Mac — it should be one click, not a transcription.
///
/// The whole design problem here is false positives. A copy button that appears on half the
/// notifications is noise, and worse, it appears on the ones where it is wrong. So the rule is
/// deliberately shy: with a word that means "code" nearby, trust a 4–8 digit run; without one,
/// only offer a code when the message contains exactly one candidate and it is at least 5 digits.
/// A message like "DEDİKONDU (6 mesaj)" or "AI · AIS Field, Milvus Robotics" produces nothing,
/// which is the point.
public enum VerificationCode {

    /// Words that make a nearby number a code, in the two languages this app ships in.
    /// Matched case- and diacritic-insensitively, so "DOĞRULAMA" and "dogrulama" both count.
    private static let keywords = [
        "code", "kod", "otp", "pin", "password", "passcode", "verification", "verify",
        "security", "token", "auth", "2fa", "one-time", "onetime",
        "doğrulama", "güvenlik", "parola", "şifre", "tek kullanımlık",
    ]

    /// A standalone run of 4 to 8 digits. `\b` keeps "A1234" and "1234abc" out: a letter next to a
    /// digit is not a boundary, so those never match.
    ///
    /// Built per call rather than stored: `Regex` is not `Sendable`, and a notification row is not
    /// a hot path — this runs a handful of times when the panel opens.
    private static var candidate: Regex<Substring> { /\b\d{4,8}\b/ }

    /// The code in this text, or `nil` when there is nothing worth offering.
    public static func find(in text: String) -> String? {
        let matches = text.matches(of: candidate).map { String($0.0) }
        guard !matches.isEmpty else { return nil }

        if hasKeyword(text) { return matches.first }

        // No keyword: only an unambiguous, long-enough single candidate. This is what stops a year
        // or an amount in ordinary prose from sprouting a copy button.
        guard matches.count == 1, matches[0].count >= 5 else { return nil }
        return matches[0]
    }

    private static func hasKeyword(_ text: String) -> Bool {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US")
        )
        return keywords.contains {
            folded.contains($0.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US")
            ))
        }
    }
}
