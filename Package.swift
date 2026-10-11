// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Impulse",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LauncherCore", targets: ["LauncherCore"]),
        .executable(name: "LauncherApp", targets: ["LauncherApp"]),
        .executable(name: "launcherctl", targets: ["LauncherCLI"]),
        .executable(name: "launcher-core-tests", targets: ["LauncherCoreTestsRunner"]),
        .executable(name: "calculator-tests", targets: ["CalculatorTestsRunner"]),
        .executable(name: "discovery-tests", targets: ["DiscoveryTestsRunner"]),
        .executable(name: "currency-tests", targets: ["CurrencyTestsRunner"]),
    ],
    dependencies: [
        .package(path: "vendor/HotKey"),
    ],
    targets: [
        .target(name: "LauncherCore"),
        .executableTarget(
            name: "LauncherApp",
            dependencies: [
                "LauncherCore",
                .product(name: "HotKey", package: "HotKey"),
            ]
        ),
        .executableTarget(name: "LauncherCLI", dependencies: ["LauncherCore"]),
        .executableTarget(
            name: "LauncherCoreTestsRunner",
            dependencies: ["LauncherCore"],
            path: "Tests/LauncherCoreTests"
        ),
        .executableTarget(name: "CalculatorTestsRunner", dependencies: ["LauncherCore"], path: "Tests/CalculatorTests"),
        .executableTarget(name: "DiscoveryTestsRunner", dependencies: ["LauncherCore"], path: "Tests/DiscoveryTests"),
        .executableTarget(name: "CurrencyTestsRunner", dependencies: ["LauncherCore"], path: "Tests/CurrencyTests"),
    ]
)
