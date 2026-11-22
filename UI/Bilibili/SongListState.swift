import Foundation
import Observation

/// 页面请求的生命周期：新请求取代旧请求，关闭页面取消；迟到结果不能覆盖新列表。
@MainActor
@Observable
final class SongListState {
    var tracks: [Track] = []
    var message: String?
    private(set) var isLoading = false
    private(set) var checked = 0
    private(set) var total = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var batchToken: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?

    typealias Progress = @Sendable (TrackListBatch) -> Void

    /// - Parameter keepList: true 时加载期间保留旧列表（队列抽屉这类秒回的本地读取：
    ///   先清空会让整列闪一帧"只有 spinner"再回填）。网络拉取仍先清空，
    ///   避免旧内容在新请求下被误读成新结果。
    @discardableResult
    func load(keepList: Bool = false,
              _ operation: @escaping @MainActor (@escaping Progress) async throws -> [Track]) async -> Bool {
        cancel()
        let token = generation
        batchToken = token
        if !keepList { tracks = [] }
        message = nil
        checked = 0
        total = 0
        isLoading = true
        let work = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == token {
                    isLoading = false
                    if batchToken == token { batchToken = nil }
                }
            }
            do {
                let result = try await operation { [weak self] batch in
                    if Thread.isMainThread {
                        MainActor.assumeIsolated {
                            self?.applyBatch(batch, token: token)
                        }
                    } else {
                        Task { @MainActor [weak self] in
                            self?.applyBatch(batch, token: token)
                        }
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                batchToken = nil
                tracks = result
                message = tracks.isEmpty ? SourceErrorPresentation.emptyResultSentinel : nil
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                batchToken = nil
                message = SourceErrorPresentation.friendly(error)
            }
        }
        task = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: { work.cancel() }
        return generation == token && !work.isCancelled && !Task.isCancelled
    }

    private func applyBatch(_ batch: TrackListBatch, token: UUID) {
        guard generation == token, batchToken == token, !Task.isCancelled else { return }
        tracks = batch.tracks
        checked = batch.checked
        total = batch.total
        message = batch.message
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
    }
}
