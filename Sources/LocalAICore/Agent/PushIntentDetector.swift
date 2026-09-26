import Foundation

/// Detects whether the user's request explicitly authorizes a git push.
/// Matches English and Korean phrasings; conservative on ambiguity.
public enum PushIntentDetector {
    private static let englishPhrases: [String] = [
        "push", "push it", "push this", "push the changes",
        "push to origin", "push to github", "push to remote",
        "publish to github", "upload to github"
    ]
    private static let koreanPhrases: [String] = [
        "푸시", "푸쉬",
        "올려줘", "올려 주세요", "올려라",
        "github에 올려", "깃허브에 올려", "깃헙에 올려",
        "원격에 올려", "리모트에 올려"
    ]

    public static func userAuthorizedPush(in request: String) -> Bool {
        let lowered = request.lowercased()
        for phrase in englishPhrases where lowered.contains(phrase) {
            return true
        }
        for phrase in koreanPhrases where request.contains(phrase) {
            return true
        }
        return false
    }
}
