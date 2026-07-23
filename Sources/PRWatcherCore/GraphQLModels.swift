import Foundation

struct GraphQLResponse: Decodable {
    let data: GraphQLData?
    let errors: [GraphQLError]?
}

struct SearchGraphQLResponse: Decodable {
    let data: SearchGraphQLData?
    let errors: [GraphQLError]?
}

struct SearchGraphQLData: Decodable {
    let viewer: Viewer
    let results: PRConnection
}

struct NodesGraphQLResponse: Decodable {
    let data: NodesGraphQLData?
    let errors: [GraphQLError]?
}

struct NodesGraphQLData: Decodable {
    let viewer: Viewer
    let nodes: [PRNode?]
}

struct DirectReviewCandidatesGraphQLResponse: Decodable {
    let data: DirectReviewCandidatesGraphQLData?
    let errors: [GraphQLError]?
}

struct DirectReviewCandidatesGraphQLData: Decodable {
    let viewer: Viewer
    let nodes: [DirectReviewCandidateNode?]
}

struct DirectReviewCandidateNode: Decodable {
    let id: String
    let state: String
    let author: LoginNode?
    let reviewRequests: ReviewRequestConnection
}

struct PullRequestSearchRESTResponse: Decodable {
    let totalCount: Int
    let incompleteResults: Bool
    let items: [PullRequestSearchRESTItem]

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case incompleteResults = "incomplete_results"
        case items
    }
}

struct PullRequestSearchRESTItem: Decodable {
    let nodeID: String

    private enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
    }
}

struct RateLimitRESTResponse: Decodable {
    let resources: RateLimitResources
}

struct RateLimitResources: Decodable {
    let graphql: RateLimitResource
    let search: RateLimitResource
}

struct RateLimitResource: Decodable {
    let limit: Int
    let used: Int
    let remaining: Int
    let reset: TimeInterval
}

struct SearchCountGraphQLResponse: Decodable {
    let data: SearchCountGraphQLData?
    let errors: [GraphQLError]?
}

struct SearchCountGraphQLData: Decodable {
    let results: SearchCountConnection
}

struct SearchCountConnection: Decodable {
    let issueCount: Int
}

struct OrganizationsGraphQLResponse: Decodable {
    let data: OrganizationsGraphQLData?
    let errors: [GraphQLError]?
}

struct OrganizationsGraphQLData: Decodable {
    let viewer: OrganizationsViewer
}

struct WatchedGraphQLResponse: Decodable {
    let data: WatchedGraphQLData?
    let errors: [GraphQLError]?
}

struct WatchedGraphQLData: Decodable {
    let repository: WatchedRepository?
}

struct WatchedRepository: Decodable {
    let pullRequest: PRNode?
}

struct PullRequestDetailsGraphQLResponse: Decodable {
    let data: PullRequestDetailsGraphQLData?
    let errors: [GraphQLError]?
}

struct PullRequestDetailsGraphQLData: Decodable {
    let repository: PullRequestDetailsRepository?
}

struct PullRequestDetailsRepository: Decodable {
    let pullRequest: PullRequestDetailsNode?
}

struct PullRequestDetailsNode: Decodable {
    let isDraft: Bool
    let reviewDecision: String?
    let mergeable: String?
    let mergeStateStatus: String?
    let state: String?
    let reviewRequests: ReviewRequestConnection
    let latestReviews: LatestReviewConnection?
    let reviewThreads: ReviewThreadConnection?
    let commits: CommitConnection
}

struct UserProfileGraphQLResponse: Decodable {
    let data: UserProfileGraphQLData?
    let errors: [GraphQLError]?
}

struct UserProfileGraphQLData: Decodable {
    let user: UserProfileNode?
}

struct UserProfileNode: Decodable {
    let login: String
    let name: String?
}

struct OrganizationsViewer: Decodable {
    let organizations: OrganizationConnection
}

struct OrganizationConnection: Decodable {
    let nodes: [OrganizationNode?]
}

struct GraphQLError: Decodable {
    let message: String
}

struct GraphQLData: Decodable {
    let viewer: Viewer
    let authored: PRConnection
    let assigned: PRConnection
    let reviewRequested: PRConnection
    let merged: PRConnection
}

struct Viewer: Decodable {
    let login: String
}

struct PRConnection: Decodable {
    let nodes: [PRNode?]
    let pageInfo: SearchPageInfo?
}

struct SearchPageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

struct PRNode: Decodable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let isDraft: Bool
    let createdAt: String?
    let mergedAt: String?
    let updatedAt: String
    let reviewDecision: String?
    let mergeable: String?
    let mergeStateStatus: String?
    let state: String?
    let viewerCanClose: Bool?
    let viewerCanUpdate: Bool?
    let viewerCanEnableAutoMerge: Bool?
    let autoMergeRequest: AutoMergeRequestNode?
    let author: LoginNode?
    let repository: RepositoryNode
    let assignees: LoginConnection
    let reviewRequests: ReviewRequestConnection
    let commits: CommitConnection
}

struct LoginNode: Decodable {
    let login: String
}

struct RepositoryNode: Decodable {
    let nameWithOwner: String
    let viewerPermission: String?
    let mergeCommitAllowed: Bool?
    let squashMergeAllowed: Bool?
    let rebaseMergeAllowed: Bool?
}

struct AutoMergeRequestNode: Decodable {
    let mergeMethod: String?
}

struct LoginConnection: Decodable {
    let nodes: [LoginNode?]
}

struct ReviewRequestConnection: Decodable {
    let nodes: [ReviewRequestNode?]
}

struct ReviewRequestNode: Decodable {
    let requestedReviewer: RequestedReviewer?
}

struct LatestReviewConnection: Decodable {
    let nodes: [LatestReviewNode?]
}

struct LatestReviewNode: Decodable {
    let state: String
    let author: LoginNode?
}

struct ReviewThreadConnection: Decodable {
    let totalCount: Int
    let nodes: [ReviewThreadNode?]
}

struct ReviewThreadNode: Decodable {
    let isResolved: Bool
}

struct RequestedReviewer: Decodable {
    let login: String?
    let name: String?
    let slug: String?
    let organization: OrganizationNode?
}

struct OrganizationNode: Decodable {
    let login: String
}

struct CommitConnection: Decodable {
    let nodes: [CommitNode?]
}

struct CommitNode: Decodable {
    let commit: Commit
}

struct Commit: Decodable {
    let statusCheckRollup: StatusCheckRollup?
}

struct StatusCheckRollup: Decodable {
    let state: String
    let contexts: StatusCheckContextConnection?
}

struct StatusCheckContextConnection: Decodable {
    let nodes: [StatusCheckContextNode?]
}

struct StatusCheckContextNode: Decodable {
    let typeName: String
    let name: String?
    let context: String?
    let status: String?
    let conclusion: String?
    let state: String?
    let detailsURL: URL?
    let targetURL: URL?
    let isRequired: Bool?

    private enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case name, context, status, conclusion, state, isRequired
        case detailsURL = "detailsUrl"
        case targetURL = "targetUrl"
    }
}
