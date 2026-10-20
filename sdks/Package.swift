// swift-tools-version: 5.10
//
// SmartWearKit: các SDK iOS của SmartWear. Mỗi loại thiết bị là một thư viện riêng, mã nguồn nằm
// cạnh bản Android của nó (sdks/<loại>/ios), dùng chung lớp BLE trong SmartWearCore.
//
//   swift build / swift test        (trên macOS, CoreBluetooth biên dịch được cả trên macOS)
import PackageDescription

let package = Package(
    name: "SmartWearKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SmartWearCore", targets: ["SmartWearCore"]),
        .library(name: "SmartWearQRing", targets: ["SmartWearQRing"]),
        .library(name: "SmartWearStandard", targets: ["SmartWearStandard"]),
        .library(name: "SmartWearGloryFit", targets: ["SmartWearGloryFit"]),
        .library(name: "SmartWearVeepoo", targets: ["SmartWearVeepoo"]),
    ],
    targets: [
        .target(
            name: "SmartWearCore", path: "core/ios/Sources/SmartWearCore",
            // DeviceManager / WearableDevice là @Observable cho SwiftUI (iOS 17). CocoaPods (React Native, iOS 15.1) không bật cờ này.
            swiftSettings: [.define("SMARTWEAR_OBSERVATION")]
        ),
        .target(name: "SmartWearQRing", dependencies: ["SmartWearCore"], path: "qring/ios/Sources/SmartWearQRing"),
        .target(name: "SmartWearStandard", dependencies: ["SmartWearCore"], path: "standard/ios/Sources/SmartWearStandard"),
        .target(name: "SmartWearGloryFit", dependencies: ["SmartWearCore"], path: "gloryfit/ios/Sources/SmartWearGloryFit"),
        .target(name: "SmartWearVeepoo", dependencies: ["SmartWearCore"], path: "veepoo/ios/Sources/SmartWearVeepoo"),
        .testTarget(name: "SmartWearCoreTests", dependencies: ["SmartWearCore"], path: "core/ios/Tests/SmartWearCoreTests"),
        .testTarget(name: "SmartWearQRingTests", dependencies: ["SmartWearQRing"], path: "qring/ios/Tests/SmartWearQRingTests"),
        .testTarget(
            name: "SmartWearStandardTests",
            dependencies: ["SmartWearStandard", "SmartWearQRing"],
            path: "standard/ios/Tests/SmartWearStandardTests"
        ),
        .testTarget(
            name: "SmartWearGloryFitTests",
            dependencies: ["SmartWearGloryFit", "SmartWearQRing"],
            path: "gloryfit/ios/Tests/SmartWearGloryFitTests"
        ),
        .testTarget(
            name: "SmartWearVeepooTests",
            dependencies: ["SmartWearVeepoo", "SmartWearQRing", "SmartWearGloryFit", "SmartWearStandard"],
            path: "veepoo/ios/Tests/SmartWearVeepooTests"
        ),
    ]
)
