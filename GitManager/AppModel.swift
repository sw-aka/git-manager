import Foundation
import Observation

@MainActor @Observable
public final class AppModel {
    public private(set) var sources: [RepoSource] = []
    public private(set) var settings = AppSettings()
    public private(set) var repos: [RepoRecord] = []
    public private(set) var busy: Set<String> = []
    public private(set) var isRefreshing = false
    public var message: String?
    public var needsAttentionOnly = false
    public var selection: String?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let limiter = WorkLimiter()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var started = false

    public init(store: Store = Store()) {
        self.store = store
        do {
            let state = try store.load()
            sources = state.sources
            settings = state.settings
            settings.fetchIntervalMinutes = settings.validatedInterval
        } catch { message = "Could not load saved sources and settings: \(error.localizedDescription)" }
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
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !sources.contains(where: { if case .local(let folder) = $0 { folder.path == path } else { false } }) else { return }
        sources.append(.local(LocalFolderSource(path: path)))
        persist()
        Task { await refreshAll() }
    }

    public func addRemote(_ remote: RemoteRepoSource) throws {
        try remote.validate()
        guard !sources.contains(where: {
            if case .remote(let source) = $0 { source.host == remote.host && source.port == remote.port && source.path == remote.path }
            else { false }
        }) else { return }
        sources.append(.remote(remote))
        persist()
        Task { await refreshAll() }
    }

    public func removeSource(_ sourceID: UUID) {
        sources.removeAll { $0.id == sourceID }
        repos.removeAll { $0.location.source.id == sourceID }
        if !repos.contains(where: { $0.id == selection }) { selection = nil }
        persist()
    }

    private func persist() {
        do { try store.save(StoredState(sources: sources, settings: settings)) }
        catch { message = "Could not save sources and settings: \(error.localizedDescription)" }
    }

    private func rescan() async {
        let sources = sources
        let discovered = await Task.detached(priority: .utility) {
            var records: [RepoRecord] = []
            for source in sources {
                switch source {
                case .remote(let remote):
                    records.append(RepoRecord(location: RepoLocation(source: source, path: remote.path)))
                case .local(let folder):
                    do {
                        for path in try Scanner().repositories(in: folder.path) {
                            records.append(RepoRecord(location: RepoLocation(source: source, path: path)))
                        }
                    } catch {
                        var record = RepoRecord(location: RepoLocation(source: source, path: folder.path))
                        record.status.error = error.localizedDescription
                        records.append(record)
                    }
                }
            }
            return records
        }.value
        let existing = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
        let currentSourceIDs = Set(self.sources.map(\.id))
        repos = discovered.filter { currentSourceIDs.contains($0.location.source.id) }.map { existing[$0.id] ?? $0 }
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
        let service = RepoService(location: repo.location)
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
        let outcome = await RepoService(location: repo.location).sync(lastFetch: repo.status.lastFetch)
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
