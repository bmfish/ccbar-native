import XCTest
@testable import CCBar

// MARK: - 创意套件（菜单栏伴侣 / 表情）

final class CreativeTests: XCTestCase {
    func testFrameIntervalTiers() {
        XCTAssertNil(PetPose.frameInterval(progress: 0), "零用量睡觉，不动画")
        XCTAssertEqual(PetPose.frameInterval(progress: 0.1), 0.55)
        XCTAssertEqual(PetPose.frameInterval(progress: 0.5), 0.30)
        XCTAssertEqual(PetPose.frameInterval(progress: 0.9), 0.15)
    }

    func testEmojiTiers() {
        XCTAssertEqual(PetPose.emoji(progress: 0), "😴")
        XCTAssertEqual(PetPose.emoji(progress: 0.2), "🙂")
        XCTAssertEqual(PetPose.emoji(progress: 0.5), "😮\u{200D}💨")
        XCTAssertEqual(PetPose.emoji(progress: 0.9), "🥵")
        XCTAssertEqual(PetPose.emoji(progress: 1.2), "🤯")
    }

}
