import XCTest
@testable import GitManagerCore

final class SourceRemovalPlanTests: XCTestCase {
    func testSelectedLocalRepoMapsAllProvidersAndCountsUnselectedReposOnce() {
        let folder = RepoSource.local(LocalFolderSource(path: "/group"))
        let direct = RepoSource.local(LocalFolderSource(path: "/group/shared"))
        let retained = RepoSource.local(LocalFolderSource(path: "/group/other"))
        let shared = RepoRecord(location: RepoLocation(source: folder, path: "/group/shared"))
            .withLocations([RepoLocation(source: folder, path: "/group/shared"),
                            RepoLocation(source: direct, path: "/group/shared")])
        let other = RepoRecord(location: RepoLocation(source: folder, path: "/group/other"))
            .withLocations([RepoLocation(source: folder, path: "/group/other"),
                            RepoLocation(source: retained, path: "/group/other")])
        let exclusive = RepoRecord(location: RepoLocation(source: folder, path: "/group/exclusive"))
        let plan = SourceRemovalPlan.forRepositories([shared.id, "unknown"],
            sources: [folder, direct, retained], repos: [shared, other, exclusive])
        XCTAssertEqual(plan.sourceIDs, [folder.id, direct.id])
        XCTAssertEqual(plan.entries.map(\.repositoryCount), [3, 1])
        XCTAssertEqual(plan.repositoryCount, 3, "Totals include unselected repos without double-counting shared providers")
        XCTAssertEqual(plan.retainedRepositoryCount, 1)
    }

    func testRemoteSelectionMapsOnlyItsSourcesAndIgnoresUnknownIDs() {
        let first = RepoSource.remote(RemoteRepoSource(host: "host", path: "/one"))
        let second = RepoSource.remote(RemoteRepoSource(host: "host", path: "/two"))
        let third = RepoSource.remote(RemoteRepoSource(host: "other", path: "/three"))
        let repos = [first, second, third].map { source in
            guard case .remote(let remote) = source else { fatalError("Expected remote source") }
            return RepoRecord(location: RepoLocation(source: source, path: remote.path))
        }
        let plan = SourceRemovalPlan.forRepositories([repos[0].id, repos[1].id],
            sources: [first, second, third], repos: repos)
        XCTAssertEqual(plan.sourceIDs, [first.id, second.id])
        XCTAssertEqual(plan.entries.map(\.repositoryCount), [1, 1])
        XCTAssertEqual(plan.repositoryCount, 2)
        XCTAssertEqual(plan.retainedRepositoryCount, 0)
        for ids: Set<String> in [[], ["unknown"]] {
            let empty = SourceRemovalPlan.forRepositories(ids, sources: [first, second, third], repos: repos)
            XCTAssertTrue(empty.sourceIDs.isEmpty)
            XCTAssertEqual(empty.repositoryCount, 0)
        }
    }

    func testExplicitFolderRemovalCanIncludeZeroRepositories() {
        let folder = RepoSource.local(LocalFolderSource(path: "/missing"))
        let plan = SourceRemovalPlan(sourceIDs: [folder.id, UUID()], sources: [folder], repos: [])
        XCTAssertEqual(plan.sourceIDs, [folder.id])
        XCTAssertEqual(plan.entries.map(\.repositoryCount), [0])
        XCTAssertEqual(plan.repositoryCount, 0)
    }

    func testUnchangedPlanProceedsDespiteSourceOrderAndStatusChanges() {
        let (sources, repos) = confirmationFixture()
        let shown = SourceRemovalPlan(sourceIDs: Set(sources.map(\.id)), sources: sources, repos: repos)
        var refreshed = Array(repos.reversed())
        refreshed[0].status.ahead = 3
        let reordered = SourceRemovalPlan(sourceIDs: shown.sourceIDs, sources: sources.reversed(), repos: refreshed)
        XCTAssertEqual(shown, reordered)
        XCTAssertEqual(shown.confirmationDecision(sources: sources.reversed(), repos: refreshed), .proceed(reordered))
    }

    func testAddedRepositoryRequiresConfirmationOfUpdatedCounts() {
        let (sources, repos) = confirmationFixture()
        let shown = SourceRemovalPlan(sourceIDs: [sources[0].id], sources: sources, repos: repos)
        let discovered = RepoRecord(location: RepoLocation(source: sources[0], path: "/review/a/new"))
        let currentRepos = repos + [discovered]
        let current = SourceRemovalPlan(sourceIDs: shown.sourceIDs, sources: sources, repos: currentRepos)
        XCTAssertNotEqual(shown, current)
        XCTAssertEqual(current.entries.map(\.repositoryCount), [3])
        XCTAssertEqual(shown.confirmationDecision(sources: sources, repos: currentRepos), .reconfirm(current))
        XCTAssertEqual(current.confirmationDecision(sources: sources, repos: currentRepos), .proceed(current),
                       "Only confirmation of the updated plan may proceed")
    }

    func testChangedPerSourceCountsRequireConfirmationEvenWhenTotalIsUnchanged() {
        let (sources, repos) = confirmationFixture()
        let shown = SourceRemovalPlan(sourceIDs: Set(sources.map(\.id)), sources: sources, repos: repos)
        let moved = repos[1].withLocations([RepoLocation(source: sources[1], path: repos[1].location.path)])
        let currentRepos = [repos[0], moved, repos[2]]
        let current = SourceRemovalPlan(sourceIDs: shown.sourceIDs, sources: sources, repos: currentRepos)
        XCTAssertEqual(shown.repositoryCount, current.repositoryCount)
        XCTAssertEqual(current.entries.map(\.repositoryCount), [1, 2])
        XCTAssertEqual(shown.confirmationDecision(sources: sources, repos: currentRepos), .reconfirm(current))
    }

    func testRemovedSourceIsDroppedAndRemainingSourcesRequireConfirmation() {
        let (sources, repos) = confirmationFixture()
        let shown = SourceRemovalPlan(sourceIDs: Set(sources.map(\.id)), sources: sources, repos: repos)
        let remainingSources = [sources[1]]
        let remainingRepos = [repos[2]]
        let current = SourceRemovalPlan(sourceIDs: shown.sourceIDs, sources: remainingSources, repos: remainingRepos)
        XCTAssertEqual(current.sourceIDs, [sources[1].id])
        XCTAssertEqual(shown.confirmationDecision(sources: remainingSources, repos: remainingRepos), .reconfirm(current))
        XCTAssertEqual(current.confirmationDecision(sources: remainingSources, repos: remainingRepos), .proceed(current))
    }

    func testAllReviewedSourcesAlreadyRemovedIsNoOpAndDoesNotTargetNewSources() {
        let (sources, repos) = confirmationFixture()
        let shown = SourceRemovalPlan(sourceIDs: [sources[0].id], sources: sources, repos: repos)
        XCTAssertEqual(shown.confirmationDecision(sources: [sources[1]], repos: [repos[2]]), .noOp)
        XCTAssertEqual(shown.confirmationDecision(sources: [], repos: []), .noOp)
    }

    func testChangedRetentionCountRequiresConfirmation() {
        let (sources, repos) = confirmationFixture()
        let shown = SourceRemovalPlan(sourceIDs: [sources[0].id], sources: sources, repos: repos)
        let shared = repos[0].withLocations(repos[0].locations + [RepoLocation(source: sources[1], path: repos[0].location.path)])
        let currentRepos = [shared, repos[1], repos[2]]
        let current = SourceRemovalPlan(sourceIDs: shown.sourceIDs, sources: sources, repos: currentRepos)
        XCTAssertEqual(shown.entries, current.entries)
        XCTAssertEqual(shown.repositoryCount, current.repositoryCount)
        XCTAssertEqual(current.retainedRepositoryCount, 1)
        XCTAssertEqual(shown.confirmationDecision(sources: sources, repos: currentRepos), .reconfirm(current))
    }

    private func confirmationFixture() -> (sources: [RepoSource], repos: [RepoRecord]) {
        let sources = [RepoSource.local(LocalFolderSource(path: "/review/a")),
                       RepoSource.local(LocalFolderSource(path: "/review/b"))]
        let repos = [RepoRecord(location: RepoLocation(source: sources[0], path: "/review/a/one")),
                     RepoRecord(location: RepoLocation(source: sources[0], path: "/review/a/two")),
                     RepoRecord(location: RepoLocation(source: sources[1], path: "/review/b/three"))]
        return (sources, repos)
    }
}
