// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "FermixPet",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FermixPet", targets: ["FermixPet"])
    ],
    targets: [
        .executableTarget(
            name: "FermixPet",
            exclude: ["Info.plist"],
            resources: [.process("Resources")],
            linkerSettings: [
                .unsafeFlags(
                    [
                        "-Xlinker", "-sectcreate",
                        "-Xlinker", "__TEXT",
                        "-Xlinker", "__info_plist",
                        "-Xlinker", "Sources/FermixPet/Info.plist"
                    ],
                    .when(platforms: [.macOS])
                )
            ]
        )
    ]
)
