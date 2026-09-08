// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotonMigrateBar",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "PhotonMigrateBar",
            path: "Sources/PhotonMigrateBar",
            exclude: ["Info.plist"],
            linkerSettings: [
                // LSUIElement=YES suppresses the Dock icon/app switcher entry,
                // making this a menu-bar-only app -- same Info.plist embedding
                // trick used by photos-helper for NSPhotoLibraryUsageDescription.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/PhotonMigrateBar/Info.plist",
                ])
            ]
        ),
    ]
)
