// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgorApp",
    platforms: [
        .iOS(.v17)
    ],
    products: [],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/textual.git", from: "0.3.0"),
        .package(url: "https://github.com/socketio/socket.io-client-swift.git", from: "16.1.1"),
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.2.1"),
    ],
    targets: [
        .executableTarget(
            name: "AgorApp",
            dependencies: [
                .product(name: "Textual", package: "textual"),
                .product(name: "SocketIO", package: "socket.io-client-swift"),
                "Highlightr",
            ],
            path: "AgorApp",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "AgorAppTests",
            dependencies: ["AgorApp"],
            path: "AgorAppTests"
        ),
    ]
)
