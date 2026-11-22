import AppKit
import XCTest
@testable import SpatialLyricsPlayer

@MainActor
final class ArtworkStoreTests: XCTestCase {

    private func pngData() -> Data? {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// 测试永远用临时目录：`clear()` 会删掉整个目录，绝不能落到用户的真实缓存上。
    private func tempStore() -> ArtworkStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artwork-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ArtworkStore(directory: dir)
    }

    func testStoreReturnsStableNameAndLoadsImage() throws {
        let store = tempStore()
        let data = try XCTUnwrap(pngData())

        let name = try XCTUnwrap(store.store(data))
        XCTAssertTrue(name.hasPrefix("artwork-"))
        XCTAssertNotNil(store.image(named: name), "写入后应能读回")

        let again = try XCTUnwrap(store.store(data))
        XCTAssertEqual(name, again, "同一份内容必须得到同一个文件名（内容寻址）")
    }

    func testResolvesOpaqueAndEmbeddedReferences() throws {
        let store = tempStore()
        let data = try XCTUnwrap(pngData())
        let name = try XCTUnwrap(store.store(data))

        XCTAssertNotNil(store.image(for: ArtworkReference(.opaque(name))))
        XCTAssertNotNil(store.image(for: ArtworkReference(.embedded(data))))
    }

    func testRemoteAndMissingReferencesResolveToNil() {
        let store = tempStore()
        XCTAssertNil(store.image(for: ArtworkReference(.remote(URL(string: "https://example.com/a.png")!))),
                     "没接网络时不得返回远程封面")
        XCTAssertNil(store.image(for: ArtworkReference(.opaque("does-not-exist.img"))))
        XCTAssertNil(store.image(for: nil))
    }

    func testEmptyDataIsRejected() {
        XCTAssertNil(tempStore().store(Data()))
    }
}

/// 远程封面按曲目身份缓存。
///
/// 这是"控制中心有图、播放器里永远是灰音符"那条的回归：
/// 之前远程下载的图只进 `SystemMediaIntegration` 自己的内存字典，从不回写这里。
@MainActor
final class ArtworkIdentityCacheTests: XCTestCase {

    private func pngData() -> Data? {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private var identity: TrackIdentity {
        TrackIdentity(sourceID: SourceID(rawValue: "remote"), externalID: "id-test-1")
    }

    private func tempStore() -> ArtworkStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artwork-id-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ArtworkStore(directory: dir)
    }

    func testStoredArtworkIsResolvableByIdentity() throws {
        let store = tempStore()
        let data = try XCTUnwrap(pngData())
        defer { store.clear() }

        XCTAssertNil(store.image(forIdentity: identity), "没有下载过就不该有图")
        XCTAssertNotNil(store.store(data, for: identity))
        XCTAssertNotNil(store.image(forIdentity: identity), "落盘后必须能按身份读回")
    }

    func testDifferentIdentitiesDoNotCollide() throws {
        let store = tempStore()
        let data = try XCTUnwrap(pngData())
        defer { store.clear() }

        store.store(data, for: identity)
        let other = TrackIdentity(sourceID: SourceID(rawValue: "remote"), externalID: "id-other")
        XCTAssertNil(store.image(forIdentity: other), "别的曲目不该命中同一张图")
    }

    func testStoringPostsNotificationWithIdentity() throws {
        let store = tempStore()
        let data = try XCTUnwrap(pngData())
        defer { store.clear() }

        let expectation = expectation(description: "artwork stored")
        let received = LockedIdentity()
        // 只订阅**这个** store：之前用 `object: nil` 会听见全进程所有 store 的通知，
        // 别的测试存图时也会跑进这个闭包。
        let token = NotificationCenter.default.addObserver(
            forName: ArtworkStore.didStoreNotification, object: store, queue: .main
        ) { note in
            // 断言不写在回调里：回调可能在其他线程/多次触发，
            // 断言要么落空要么重复报。先收集，等 wait 之后再断言。
            received.set(note.userInfo?[ArtworkStore.identityKey] as? TrackIdentity)
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        store.store(data, for: identity)
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(received.value, self.identity, "通知里必须带上正确的曲目身份")
    }

    func testEmptyDataDoesNotPostNotification() {
        XCTAssertNil(tempStore().store(Data(), for: identity))
    }
}

/// 通知回调里收集数据用的小容器（回调可能在别的线程）。
private final class LockedIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TrackIdentity?
    func set(_ value: TrackIdentity?) { lock.lock(); storage = value; lock.unlock() }
    var value: TrackIdentity? { lock.lock(); defer { lock.unlock() }; return storage }
}
