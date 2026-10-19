import XCTest
@testable import SmartWearCore

/// Nhóm API điện thoại ↔ thiết bị (kế hoạch 2026-10-19 §2): mặc định "không hỗ trợ, không làm gì", tên hằng trùng Kotlin.
@MainActor
final class PhoneLinkTests: XCTestCase {
    func testDefaultsAreUnsupported() async {
        let d = WearableDevice(id: UUID(), driverId: "x", name: "X", kind: .unknown)
        XCTAssertFalse(d.supportsNotifications)
        XCTAssertNil(d.ancsAuthorized)
        XCTAssertFalse(d.supportsIncomingCall)
        XCTAssertFalse(d.supportsRejectCall)
        XCTAssertFalse(d.supportsMusicControl)
        XCTAssertFalse(d.supportsTrackInfo)
        XCTAssertFalse(d.supportsSmsReply)
        XCTAssertEqual(0, d.maxContacts)
        XCTAssertFalse(d.supportsClearContacts)
        XCTAssertFalse(d.supportsCallAudio)
        XCTAssertFalse(d.supportsWatchFace)
        XCTAssertFalse(d.supportsWatchFaceSlots)
        XCTAssertFalse(d.supportsWorkoutControl)
        XCTAssertFalse(d.supportsSportList)
        XCTAssertFalse(d.supportsPhoneLocation)
        // Không làm gì, không ném.
        await d.setMusicState(MusicState(playing: true, title: "A"))
        await d.setMusicVolume(50)
        await d.incomingCall(name: "A", number: "1")
        await d.callEnded()
    }

    func testDefaultsThrow() async {
        let d = WearableDevice(id: UUID(), driverId: "x", name: "X", kind: .unknown)
        await assertThrows { _ = try await d.syncContacts([Contact(name: "A", phone: "1")]) }
        await assertThrows { try await d.clearContacts() }
        await assertThrows { _ = try await d.callAudioState() }
        await assertThrows { try await d.setCallAudio(true) }
        await assertThrows { _ = try await d.watchFaceInfo() }
        await assertThrows { try await d.installWatchFace(Data()) }
        await assertThrows { _ = try await d.watchFaceSlots() }
        await assertThrows { try await d.deleteWatchFaceSlot(1) }
        await assertThrows { _ = try await d.sportTypes() }
        await assertThrows { try await d.setSportList([]) }
        await assertThrows { try await d.startWorkout(1) }
        await assertThrows { try await d.pauseWorkout() }
        await assertThrows { try await d.resumeWorkout() }
        await assertThrows { try await d.stopWorkout() }
        await assertThrows { try await d.sendLocation(latitude: 21, longitude: 105) }
        do {
            try await d.pairCallAudio()
            XCTFail("phải ném lỗi")
        } catch let e as CallAudioPairingError {
            XCTAssertTrue(e.localizedDescription.contains("Cài đặt > Bluetooth"))
        } catch {
            XCTFail("sai loại lỗi \(error)")
        }
    }

    func testRawValuesMatchKotlin() {
        XCTAssertEqual(["PLAY_PAUSE", "NEXT", "PREVIOUS", "VOLUME_UP", "VOLUME_DOWN"], MusicCommand.allCases.map(\.rawValue))
        XCTAssertEqual("STARTED", WorkoutState.started.rawValue)
        XCTAssertEqual("STOPPED", WorkoutState.stopped.rawValue)
        XCTAssertEqual("LONG_PRESS_BUTTON_2", DeviceEvent.longPressButton2.rawValue)
    }

    func testPairingErrorNamesDevice() {
        XCTAssertEqual(
            "iOS không cho app ghép đôi Bluetooth cổ điển: mở Cài đặt > Bluetooth và chọn \"Y25\"",
            CallAudioPairingError(deviceName: "Y25").errorDescription
        )
    }

    func testControlConfirmDefaultsNil() {
        XCTAssertNil(DeviceControl("a", group: "g", title: "t", kind: .action).confirm)
        XCTAssertEqual("?", DeviceControl("a", group: "g", title: "t", kind: .action, confirm: "?").confirm)
    }

    private func assertThrows(_ body: () async throws -> Void, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("phải ném lỗi", line: line)
        } catch {}
    }
}
