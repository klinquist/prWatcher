import Foundation
import Testing
@testable import PRWatcherCore

@Test("GraphQL results are de-duplicated and assigned through a team")
func decodeSnapshot() throws {
    let json = #"""
    {
      "data": {
        "viewer": { "login": "octocat" },
        "authored": { "nodes": [
          {
            "id": "PR_author",
            "number": 42,
            "title": "Ship it",
            "url": "https://github.com/acme/widgets/pull/42",
            "isDraft": false,
            "mergedAt": null,
            "updatedAt": "2026-07-22T12:00:00Z",
            "reviewDecision": "APPROVED",
            "mergeable": "MERGEABLE",
            "author": { "login": "octocat" },
            "repository": { "nameWithOwner": "acme/widgets" },
            "assignees": { "nodes": [] },
            "reviewRequests": { "nodes": [] },
            "commits": { "nodes": [{ "commit": { "statusCheckRollup": { "state": "SUCCESS" } } }] }
          }
        ] },
        "assigned": { "nodes": [] },
        "reviewRequested": { "nodes": [
          {
            "id": "PR_team",
            "number": 9,
            "title": "Team review",
            "url": "https://github.com/acme/widgets/pull/9",
            "isDraft": false,
            "mergedAt": null,
            "updatedAt": "2026-07-22T11:00:00Z",
            "reviewDecision": "REVIEW_REQUIRED",
            "mergeable": "MERGEABLE",
            "author": { "login": "hubot" },
            "repository": { "nameWithOwner": "acme/widgets" },
            "assignees": { "nodes": [] },
            "reviewRequests": { "nodes": [{
              "requestedReviewer": {
                "login": null,
                "name": "Platform",
                "slug": "platform",
                "organization": { "login": "acme" }
              }
            }] },
            "commits": { "nodes": [{ "commit": { "statusCheckRollup": { "state": "PENDING" } } }] }
          }
        ] },
        "merged": { "nodes": [] }
      }
    }
    """#

    let snapshot = try GitHubClient.decodeSnapshot(Data(json.utf8))
    #expect(snapshot.viewerLogin == "octocat")
    #expect(snapshot.pullRequests.count == 2)

    let authored = try #require(snapshot.pullRequests.first { $0.id == "PR_author" })
    #expect(authored.section == .readyToMerge)

    let assigned = try #require(snapshot.pullRequests.first { $0.id == "PR_team" })
    #expect(assigned.section == .assigned)
    #expect(assigned.assignment == .teams(["@acme/platform"]))
}

@Test("A single search response decodes independently")
func decodeSearchResponse() throws {
    let json = #"""
    {
      "data": {
        "viewer": { "login": "octocat" },
        "results": {
          "pageInfo": { "hasNextPage": true, "endCursor": "cursor-10" },
          "nodes": []
        }
      }
    }
    """#

    let result = try GitHubClient.decodeSearch(Data(json.utf8))
    #expect(result.viewer == "octocat")
    #expect(result.nodes.isEmpty)
    #expect(result.hasNextPage)
    #expect(result.endCursor == "cursor-10")
}

@Test("Gateway HTTP failures are recognized as transient")
func transientGatewayErrors() {
    #expect(GitHubClient.isTransientGatewayError("gh: HTTP 502: Bad Gateway"))
    #expect(GitHubClient.isTransientGatewayError("HTTP 503 Service Unavailable"))
    #expect(GitHubClient.isTransientGatewayError("Gateway Timeout"))
    #expect(!GitHubClient.isTransientGatewayError("HTTP 401: Bad credentials"))
    #expect(
        GitHubClient.partialRefreshWarning(["Merged", "Assigned to me", "Merged"])
            == "Couldn’t refresh Assigned to me, Merged. Showing the previous results for those sections."
    )
    #expect(GitHubClient.partialRefreshWarning([]) == nil)
}

@Test("GraphQL search arguments use variables and a bounded result count")
func graphQLSearchArguments() {
    let arguments = GitHubClient.graphQLArguments(query: "is:pr author:@me", count: 50)
    #expect(arguments.contains("searchQuery=is:pr author:@me"))
    #expect(arguments.contains("count=50"))
    #expect(GitHubClient.graphQLQuery.contains("$searchQuery"))
    #expect(GitHubClient.graphQLQuery.contains("viewerCanClose"))
    #expect(GitHubClient.graphQLQuery.contains("viewerCanUpdate"))
    #expect(GitHubClient.graphQLQuery.contains("viewerCanEnableAutoMerge"))
    #expect(GitHubClient.graphQLQuery.contains("viewerPermission"))
    #expect(GitHubClient.graphQLQuery.contains("mergeStateStatus"))
    #expect(GitHubClient.graphQLQuery.contains("after: $after"))

    let nextPageArguments = GitHubClient.graphQLArguments(
        query: "is:pr review-requested:@me",
        count: 10,
        after: "cursor-10"
    )
    #expect(nextPageArguments.contains("after=cursor-10"))
}

@Test("Only write-capable repository roles imply merge permission")
func repositoryMergePermission() {
    #expect(GitHubClient.permissionAllowsMerging("WRITE"))
    #expect(GitHubClient.permissionAllowsMerging("MAINTAIN"))
    #expect(GitHubClient.permissionAllowsMerging("ADMIN"))
    #expect(!GitHubClient.permissionAllowsMerging("TRIAGE"))
    #expect(!GitHubClient.permissionAllowsMerging("READ"))
    #expect(!GitHubClient.permissionAllowsMerging(nil))
}

@Test("Built-in authored sections use separate focused search qualifiers")
func authoredSectionSearchQualifiers() {
    #expect(GitHubClient.authoredSearchQualifier(for: .drafts) == "is:draft")
    #expect(GitHubClient.authoredSearchQualifier(for: .readyToMerge) == "draft:false review:approved")
    #expect(GitHubClient.authoredSearchQualifier(for: .waitingForCI) == "draft:false status:pending")
    #expect(GitHubClient.authoredSearchQualifier(for: .failingCI) == "draft:false")
    #expect(GitHubClient.authoredSearchQualifier(for: .waitingForReview) == "draft:false")
}

@Test("Direct review requests use the explicit viewer login")
func directReviewRequestQualifier() {
    #expect(GitHubClient.reviewRequestQualifier(
        includeTeamReviewRequests: false,
        viewerLogin: "Octo-Cat"
    ) == "review-requested:Octo-Cat")
    #expect(GitHubClient.reviewRequestQualifier(
        includeTeamReviewRequests: false,
        viewerLogin: ""
    ) == nil)
    #expect(GitHubClient.reviewRequestQualifier(
        includeTeamReviewRequests: true,
        viewerLogin: "Octo-Cat"
    ) == "review-requested:@me")
}

@Test("Custom searches imply pull requests without rewriting the query")
func customSearchQuery() {
    let query = "is:open team-review-requested:verkada/web-access draft:false"
    #expect(GitHubClient.customSearchQuery(query) == "is:pr \(query)")
    #expect(GitHubClient.customSearchQuery("  IS:PR is:open label:urgent  ") == "IS:PR is:open label:urgent")
}

@Test("Custom search counts decode and browser URLs use the resolved query")
func customSearchValidation() throws {
    let json = #"{"data":{"results":{"issueCount":37}}}"#
    #expect(try GitHubClient.decodeCustomSearchCount(Data(json.utf8)) == 37)

    let arguments = GitHubClient.customSearchCountArguments(query: "is:pr is:open label:urgent")
    #expect(arguments.contains("searchQuery=is:pr is:open label:urgent"))

    let url = try #require(GitHubClient.customSearchURL(query: "is:open label:urgent"))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "github.com")
    #expect(components.path == "/pulls")
    #expect(components.queryItems?.first(where: { $0.name == "q" })?.value == "is:pr is:open label:urgent")
}

@Test("Organizations decode and sort by login")
func decodeOrganizations() throws {
    let json = #"""
    {
      "data": {
        "viewer": {
          "organizations": {
            "nodes": [
              { "login": "Zebra-Labs" },
              { "login": "acme" }
            ]
          }
        }
      }
    }
    """#

    #expect(try GitHubClient.decodeOrganizations(Data(json.utf8)) == ["acme", "Zebra-Labs"])
}

@Test("Organization search qualifiers are constrained to GitHub logins")
func organizationQualifier() {
    #expect(GitHubClient.organizationQualifier(nil).isEmpty)
    #expect(GitHubClient.organizationQualifier("").isEmpty)
    #expect(GitHubClient.organizationQualifier("acme-tools") == " org:acme-tools")
    #expect(GitHubClient.organizationQualifier("acme org:unexpected").isEmpty)
}

@Test("A watched pull request response decodes its current state")
func decodeWatchedPullRequest() throws {
    let json = #"""
    {
      "data": {
        "repository": {
          "pullRequest": {
            "id": "PR_watched",
            "number": 123,
            "title": "Keep an eye on this",
            "url": "https://github.com/acme/widgets/pull/123",
            "isDraft": false,
            "createdAt": "2026-07-20T10:30:00Z",
            "mergedAt": null,
            "updatedAt": "2026-07-22T12:00:00Z",
            "reviewDecision": "APPROVED",
            "mergeable": "MERGEABLE",
            "state": "OPEN",
            "viewerCanClose": true,
            "viewerCanUpdate": false,
            "viewerCanEnableAutoMerge": true,
            "author": { "login": "hubot" },
            "repository": { "nameWithOwner": "acme/widgets", "viewerPermission": "WRITE" },
            "assignees": { "nodes": [] },
            "reviewRequests": { "nodes": [] },
            "commits": { "nodes": [{ "commit": { "statusCheckRollup": { "state": "SUCCESS" } } }] }
          }
        }
      }
    }
    """#

    let node = try GitHubClient.decodeWatchedPullRequest(Data(json.utf8))
    #expect(node.id == "PR_watched")
    #expect(node.state == "OPEN")
    #expect(node.createdAt == "2026-07-20T10:30:00Z")
    #expect(node.viewerCanClose == true)
    #expect(node.viewerCanUpdate == false)
    #expect(node.viewerCanEnableAutoMerge == true)
    #expect(node.repository.viewerPermission == "WRITE")
    #expect(node.commits.nodes.compactMap { $0 }.first?.commit.statusCheckRollup?.state == "SUCCESS")
}

@Test("GitHub usernames are normalized and constrained")
func normalizeGitHubLogin() {
    #expect(GitHubClient.normalizedGitHubLogin(" @Octo-Cat ") == "Octo-Cat")
    #expect(GitHubClient.normalizedGitHubLogin("-invalid") == nil)
    #expect(GitHubClient.normalizedGitHubLogin("invalid user") == nil)
}

@Test("GitHub profiles use a real name when available")
func decodeGitHubProfile() throws {
    let namedJSON = #"""
    { "data": { "user": { "login": "octocat", "name": "The Octocat" } } }
    """#
    let named = try GitHubClient.decodeUserProfile(Data(namedJSON.utf8))
    #expect(named.login == "octocat")
    #expect(named.name == "The Octocat")
    #expect(named.displayName == "The Octocat (@octocat)")

    let unnamedJSON = #"""
    { "data": { "user": { "login": "hubot", "name": null } } }
    """#
    let unnamed = try GitHubClient.decodeUserProfile(Data(unnamedJSON.utf8))
    #expect(unnamed.displayName == "@hubot")
}
