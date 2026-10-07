import Foundation
import Observation

@MainActor @Observable
public final class AppModel {
    public private(set) var sources: [RepoSource] = []
    public private(set) var settings = AppSettings()
    public private(set) var repos: [RepoRecord] = []
    public private(set) var sourceScanErrors: [UUID: [ScanIssue]] = [:]
    public private(set) var busy: Set<String> = []
    public private(set) var isRefreshing = false
    public var message: String?
    public var needsAttentionOnly = false
    public var selection: String?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let serviceFactory: @Sendable (RepoLocation) -> RepoService
    @ObservationIgnored private var persistenceEnabled = true
    @ObservationIgnored private let limiter = WorkLimiter()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var started = false

    public convenience init(store: Store = Store()) {
        self.init(store: store, serviceFactory: { RepoService(location: $0) })
    }

    init(store: Store, serviceFactory: @escaping @Sendable (RepoLocation) -> RepoService) {
        self.store = store
        self.serviceFactory = serviceFactory
        do {
            let loaded = try store.loadRecovering()
            sources = loaded.state.sources.map { source in
                if case .remote(let remote) = source { return .remote(remote.normalized) }
                return source
            }
            settings = loaded.state.settings
            message = loaded.notice
            settings.fetchIntervalMinutes = settings.validatedInterval
        } catch {
            persistenceEnabled = false
            message = "Could not load saved sources and settings. The existing file is unchanged and saving is disabled: \(error.localizedDescription)"
        }
    }

    public var visibleRepos: [RepoRecord] { repos.filter { !needsAttentionOnly || $0.status.needsAttention } }
    public var syncRepos: [RepoRecord] { repos.filter { $0.status.needsSync } }
    public var menuBarTitle: String { syncRepos.isEmpty ? "" : String(syncRepos.count) }
    public var selectedRepo: RepoRecord? { repos.first { $0.id == selection } }

    public func start() async {
        guard !started else { return }
        started = true
        await refreshAll(fetch: false)
        scheduleTimer()
        await refreshAll(fetch: true)
    }

    public func setInterval(_ minutes: Int) {
        settings.fetchIntervalMinutes = min(1440, max(1, minutes))
        persist()
        if started { scheduleTimer() }
    }

    private func scheduleTimer() {
        timer?.cancel()
        let seconds = settings.validatedInterval * 60
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard let self else { return }
                await self.refreshAll(fetch: true)
            }
        }
    }

    public func addLocal(_ url: URL) {
        let path = RepoLocation.canonicalLocalPath(url.path)
        guard !sources.contains(where: { if case .local(let folder) = $0 { RepoLocation.canonicalLocalPath(folder.path) == path } else { false } }) else { return }
        sources.append(.local(LocalFolderSource(path: path)))
        persist()
        Task { await refreshAll() }
    }

    public func addRemote(_ remote: RemoteRepoSource) throws {
        try remote.validate()
        let remote = remote.normalized
        let identity = RepoLocation(source: .remote(remote), path: remote.path).id
        guard !sources.contains(where: {
            if case .remote(let source) = $0 { RepoLocation(source: $0, path: source.path).id == identity }
            else { false }
        }) else { throw ValidationError.message("This remote repository is already added.") }
        sources.append(.remote(remote))
        persist()
        Task { await refreshAll() }
    }

    public func removeSource(_ sourceID: UUID) {
        sources.removeAll { $0.id == sourceID }
        sourceScanErrors.removeValue(forKey: sourceID)
        repos = repos.compactMap { repo in
            let remaining = repo.locations.filter { $0.source.id != sourceID }
            return remaining.isEmpty ? nil : repo.withLocations(remaining)
        }
        if !repos.contains(where: { $0.id == selection }) { selection = nil }
        persist()
    }

    private func persist() {
        guard persistenceEnabled else { return }
        do { try store.save(StoredState(sources: sources, settings: settings)) }
        catch { message = "Could not save sources and settings: \(error.localizedDescription)" }
    }

    private func rescan() async {
        let sources = sources
        let discovered = await Task.detached(priority: .utility) {
            var records: [RepoRecord] = []
            var errors: [UUID: [ScanIssue]] = [:]
            for source in sources {
                switch source {
                case .remote(let remote):
                    records.append(RepoRecord(location: RepoLocation(source: source, path: remote.path)))
                case .local(let folder):
                    do {
                        let scan = try Scanner().scan(in: folder.path)
                        errors[source.id] = scan.issues
                        for path in scan.repositories {
                            records.append(RepoRecord(location: RepoLocation(source: source, path: path)))
                        }
                    } catch {
                        errors[source.id] = [ScanIssue(path: folder.path, message: error.localizedDescription)]
                    }
                }
            }
            return (records: records, errors: errors)
        }.value
        let existing = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
        let currentSourceIDs = Set(self.sources.map(\.id))
        sourceScanErrors = discovered.errors.filter { currentSourceIDs.contains($0.key) && !$0.value.isEmpty }
        var consolidated: [RepoRecord] = []
        var indices: [String: Int] = [:]
        for repo in discovered.records where currentSourceIDs.contains(repo.location.source.id) {
            if let index = indices[repo.id] {
                let previous = consolidated[index]
                consolidated[index] = previous.withLocations(previous.locations + repo.locations)
            } else {
                indices[repo.id] = consolidated.count
                consolidated.append(existing[repo.id]?.withLocations(repo.locations) ?? repo)
            }
        }
        repos = consolidated
        if !repos.contains(where: { $0.id == selection }) { selection = nil }
    }

    public func refreshAll(fetch: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let scannedSources = sources
        await rescan()
        let ids = repos.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            for _ in 0..<min(4, ids.count) {
                let id = ids[next]
                next += 1
                group.addTask { await self.refresh(id, fetch: fetch) }
            }
            while await group.next() != nil {
                if next < ids.count {
                    let id = ids[next]
                    next += 1
                    group.addTask { await self.refresh(id, fetch: fetch) }
                }
            }
        }
        isRefreshing = false
        // Include sources added while the discovery pass was in progress.
        if sources != scannedSources { await refreshAll(fetch: fetch) }
    }

    public func refresh(_ id: String, fetch: Bool = true) async {
        guard !busy.contains(id), let repo = repos.first(where: { $0.id == id }) else { return }
        busy.insert(id)
        await limiter.acquire()
        let service = serviceFactory(repo.location)
        var lastFetch = repo.status.lastFetch
        var error: String?
        if fetch {
            let result = await service.fetch()
            if result.succeeded { lastFetch = Date() } else { error = result.failureMessage }
        }
        let snapshot = await service.snapshot(lastFetch: lastFetch, operationError: error)
        apply(snapshot, to: id)
        await limiter.release()
        busy.remove(id)
    }

    public func sync(_ id: String) async {
        guard !busy.contains(id), let repo = repos.first(where: { $0.id == id }), repo.status.canSync else { return }
        busy.insert(id)
        await limiter.acquire()
        let outcome = await serviceFactory(repo.location).sync(lastFetch: repo.status.lastFetch)
        apply(outcome.snapshot, to: id)
        await limiter.release()
        busy.remove(id)
    }

    public func openInZed(_ id: String) async {
        guard let repo = repos.first(where: { $0.id == id }) else { return }
        let result = await ZedLauncher().open(repo.location)
        if !result.succeeded, let index = repos.firstIndex(where: { $0.id == id }) {
            repos[index].status.error = result.failureMessage
        }
    }

    private func apply(_ snapshot: RepoSnapshot, to id: String) {
        guard let index = repos.firstIndex(where: { $0.id == id }) else { return }
        repos[index].status = snapshot.status
        repos[index].commits = snapshot.commits
    }
}
