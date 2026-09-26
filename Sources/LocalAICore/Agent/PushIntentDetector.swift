import Foundation

/// Detects whether the user's request explicitly authorizes a git push.
/// Matches English and Korean phrasings; conservative on ambiguity.
/// Negations ("don't push", "푸시하지 마", "without pushing", ...) never
/// authorize, even when a push keyword is present.
public enum PushIntentDetector {
    private static let englishPhrases: [String] = [
        "push", "push it", "push this", "push the changes",
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
        // Korean
        "하지 마", "하지마", "하지 말고", "하지말고",
        "말고", "없이", "안 해", "안해", "하지 않고", "하지않고",
        "올리지 마", "올리지마", "올리지 말고"
    ]

    public static func userAuthorizedPush(in request: String) -> Bool {
        let lowered = request.lowercased()
        // Negation veto first — a push keyword under negation is not consent.
        for negation in negations where lowered.contains(negation) {
            return false
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
}
