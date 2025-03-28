// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let filename = "openssl.xcframework.zip"
let version = "3.4.301"
let checksum = "1d42181bdeb0d2cb7ec92b8dd3ea7363a398f2705ea566b2cb306b49ad9f05aa"

let package = Package(
    name: "openssl-apple",
    products: [
        .library(
            name: "openssl-apple",
            targets: ["openssl"]),
    ],
    dependencies: [
    ],
    targets: [
        .binaryTarget(
            name: "openssl",
            url: "https://github.com/iljs/openssl/releases/download/\(version)/\(filename)",
            checksum: checksum
        ),

        // local development
//        .binaryTarget(
//            name: "openssl",
//            path: "frameworks/openssl.xcframework.zip")
    ]
)
