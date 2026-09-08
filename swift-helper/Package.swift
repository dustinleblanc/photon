// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "photos-helper",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "photos-helper",
            path: "Sources/photos-helper",
            linkerSettings: [
                // PhotoKit requires an embedded Info.plist with
                // NSPhotoLibraryUsageDescription, even for a plain CLI binary.
                // This embeds it directly into the __TEXT,__info_plist section
                // of the built executable, since SPM doesn't otherwise produce
                // an Info.plist for executable targets.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/photos-helper/Info.plist",
                ])
            ]
        ),
    ]
)
