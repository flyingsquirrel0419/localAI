import Foundation

/// Detects whether the user's request explicitly authorizes a git push.
/// Matches English and Korean phrasings; conservative on ambiguity.
/// Negations ("don't push", "푸시하지 마", "without pushing", "push later", ...)
/// never authorize, even when a push keyword is present. Substring matches
/// like "pushNotification" do NOT authorize (word-boundary match on "push").
/// "force push" / "force-push" never authorizes.
public enum PushIntentDetector {
    /// Phrases that imply a push but don't contain the literal word "push"
    /// (which is matched separately with word boundaries).
    private static let englishPhrases: [String] = [
        "push it", "push this", "push the changes",
        "push to origin", "push to github", "push to remote",
        "publish to github", "upload to github"
    ]
    private static let koreanPhrases: [String] = [
        "푸시", "푸쉬",
        "올려줘", "올려 주세요", "올려라", "올려",
        "github에 올려", "깃허브에 올려", "깃헙에 올려",
        "원격에 올려", "리모트에 올려"
    ]

    /// Negation markers (already lowercased for the Latin parts). Any of these
    /// appearing anywhere in the request vetoes authorization.
    private static let negations: [String] = [
        // English
        "don't push", "do not push", "dont push", "don't  push",
        "no push", "never push", "without pushing", "without a push",
        "not push", "don't publish", "do not publish", "don't upload",
        "do not upload", "without uploading",
        "push later", "push it later", "push this later",
        // Korean
        "하지 마", "하지마", "하지 말고", "하지말고",
        "말고", "없이", "안 해", "안해", "하지 않고", "하지않고",
        "올리지 마", "올리지마", "올리지 말고",
        "나중에 푸시", "나중에 push", "나중에 올려", "나중에 올릴"
    ]

    /// Force-push phrasings never authorize, even when "push" appears.
    private static let forcePhrases: [String] = [
        "force push", "force-push", "--force", "-f ",
        "강제 푸시", "강제로 푸시", "강제 push", "강제로 push"
    ]

    public static func userAuthorizedPush(in request: String) -> Bool {
        let lowered = request.lowercased()
        // Force-push never authorizes via this detector.
        for phrase in forcePhrases where lowered.contains(phrase) {
            return false
        }
        // Negation veto first — a push keyword under negation is not consent.
        for negation in negations where lowered.contains(negation) {
            return false
        }
        // Word-boundary "push": "push", "push!", "(push)" match; "pushNotification",
        // "pushed", "pushing", "repush" do NOT (we still match other phrases below).
        if containsWordPush(lowered) {
            return true
        }
        for phrase in englishPhrases where lowered.contains(phrase) {
            return true
        }
        // `lowercased()` only affects Latin; Korean text matches the raw or
        // lowered form equally, so matching against `lowered` covers mixed
        // requests like "GitHub에 올려" regardless of Latin casing.
        for phrase in koreanPhrases where lowered.contains(phrase.lowercased()) {
            return true
        }
        return false
    }

    /// True when `text` contains the standalone word "push". ASCII letters
    /// (a-z) on either side disqualify, so "pushNotification" and "pushed"
    /// don't match. Non-ASCII letters (e.g. Hangul) DO count as boundaries —
    /// "push해줘" is a legitimate push request.
    private static func containsWordPush(_ text: String) -> Bool {
        let word: [Character] = ["p", "u", "s", "h"]
        let chars = Array(text)
        guard chars.count >= word.count else { return false }
        var i = 0
        while i + word.count <= chars.count {
            var matches = true
            for j in 0..<word.count where chars[i + j] != word[j] {
                matches = false
                break
            }
            if matches {
                let beforeOK = i == 0 || !isASCIILetter(chars[i - 1])
                let afterIdx = i + word.count
                let afterOK = afterIdx == chars.count || !isASCIILetter(chars[afterIdx])
                if beforeOK && afterOK { return true }
            }
            i += 1
        }
        return false
    }

    private static func isASCIILetter(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
    }
}
