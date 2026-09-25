// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Snap",
    platforms: [.macOS(.v14)],
    targets: [
        // 不依赖 AppKit 的纯逻辑：坐标换算、文本分块、取色、翻译接口
        .target(name: "SnapCore"),
        // 菜单栏应用：截图覆盖层、标注、OCR、翻译回显、设置
        .executableTarget(name: "Snap", dependencies: ["SnapCore"]),
        .testTarget(name: "SnapCoreTests", dependencies: ["SnapCore"]),
    ],
    swiftLanguageModes: [.v5]
)
