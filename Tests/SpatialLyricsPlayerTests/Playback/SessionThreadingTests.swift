import XCTest
@testable import SpatialLyricsPlayer

/// 播放会话的"只在主线程"约束。
///
/// `BilibiliPlayerSession` 是 `@unchecked Sendable`，可变状态**没有加锁**，
/// 完全依赖"所有入口都在主线程"这条假设。之前它只写在注释里——
/// 将来任何一处从后台 Task 调用都会静默变成数据竞争。
///
/// 现在入口处有 Debug 断言，这里守住两件事：断言机制本身可用、
/// 以及"主线程调用"这条路径确实成立。
@MainActor
final class SessionThreadingTests: XCTestCase {

    func testInvariantDetectsMainThread() {
        XCTAssertTrue(HTTPStreamPlayerSession.isOnMainThread,
                      "主线程上必须被认为是主线程")
    }

    func testInvariantDetectsBackgroundThread() async {
        let onMain = await Task.detached { HTTPStreamPlayerSession.isOnMainThread }.value
        XCTAssertFalse(onMain, "后台线程必须被识别出来，否则断言形同虚设")
    }

    /// 断言本身不能误伤：在主线程上调用不应崩溃。
    func testRequireMainThreadPassesOnMain() {
        HTTPStreamPlayerSession.requireMainThread()
        XCTAssertTrue(HTTPStreamPlayerSession.isOnMainThread)
    }
}
