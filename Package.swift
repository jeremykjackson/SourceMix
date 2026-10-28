// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SourceMix",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SourceMix", targets: ["SourceMix"])
    ],
    targets: [
        .executableTarget(
            name: "SourceMix",
            path: "Sources/SourceMix",
            exclude: ["Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                // Embed Info.plist so `swift run` builds still carry the
                // audio-capture usage string and LSUIElement flag.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/SourceMix/Info.plist"
                ])
            ]
        )
    ]
)
