import Foundation

public enum PRClassifier {
    public static func section(
        isDraft: Bool,
        ciState: String?,
        reviewDecision: String?,
        mergeable: String?,
        mergeStateStatus: String? = nil
    ) -> PRSection {
        if isDraft { return .drafts }
        if mergeable == "CONFLICTING" { return .failingCI }
        let blockingCIState = blockingCIState(
            rollupState: ciState,
            mergeStateStatus: mergeStateStatus
        )
        if blockingCIState == "FAILURE" || blockingCIState == "ERROR" { return .failingCI }
        if blockingCIState == "PENDING" || blockingCIState == "EXPECTED" { return .waitingForCI }
        if reviewDecision != "APPROVED" { return .waitingForReview }
        return .readyToMerge
    }

    public static func blockingCIState(
        rollupState: String?,
        mergeStateStatus: String?
    ) -> String? {
        switch mergeStateStatus {
        case "CLEAN", "HAS_HOOKS", "UNSTABLE":
            return nil
        default:
            return rollupState
        }
    }
}
