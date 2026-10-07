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
}
