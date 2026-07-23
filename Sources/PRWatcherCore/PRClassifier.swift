import Foundation

public enum PRClassifier {
    public static func section(
        isDraft: Bool,
        ciState: String?,
        reviewDecision: String?,
        mergeable: String?
    ) -> PRSection {
        if isDraft { return .drafts }
        if mergeable == "CONFLICTING" { return .failingCI }
        if ciState == "FAILURE" || ciState == "ERROR" { return .failingCI }
        if ciState == "PENDING" || ciState == "EXPECTED" { return .waitingForCI }
        if reviewDecision != "APPROVED" { return .waitingForReview }
        return .readyToMerge
    }
}
