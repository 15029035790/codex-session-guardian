// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodexSessionGuardian",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexSessionGuardianCore", targets: ["TokenPetCore"]),
        .executable(name: "CodexSessionGuardian", targets: ["TokenPet"]),
        .executable(name: "codex-session-guardian-cli", targets: ["TokenPetCLI"]),
        .executable(name: "codex-session-guardian-tests", targets: ["TokenPetTests"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite3",
            providers: [.brew(["sqlite3"])]),
        .target(name: "TokenPetCore", dependencies: ["CSQLite3"]),
        .executableTarget(
            name: "TokenPet",
            dependencies: ["TokenPetCore"],
            exclude: [
                "Resources/shinchan-chroma.png",
                "Resources/shinchan-dance-chroma.png",
                "Resources/shinchan.png",
                "Resources/shinchan-dance.png",
                "Resources/ActionKamen",
            ],
            resources: [
                .copy("Resources/PetAnimations"),
            ]),
        .executableTarget(name: "TokenPetCLI", dependencies: ["TokenPetCore"]),
        .executableTarget(name: "TokenPetTests", dependencies: ["TokenPetCore"]),
    ],
    swiftLanguageModes: [.v5]
)
