// swift-tools-version:6.0
import PackageDescription

// libsmb2 作为「静态库」对外暴露 SMB2 模块。
//
// 关键点：这里刻意使用静态链接（不声明 type: .dynamic）。
// 静态库会被直接编译进使用方（SMBKeepAppEx）的二进制，
// 不会产生需要单独签名的独立 .dylib / framework，
// 因此可以开启 hardened runtime 的 library validation，
// 无需再依赖 com.apple.security.cs.disable-library-validation。
let package = Package(
    name: "libsmb2",
    platforms: [
        .macOS(.v11),
    ],
    products: [
        .library(
            name: "SMB2",
            targets: ["libsmb2"]
        ),
    ],
    targets: [
        .target(
            name: "libsmb2",
            path: ".",
            exclude: [
                "lib/CMakeLists.txt",
                "lib/libsmb2.syms",
                "lib/Makefile.am",
                "lib/Makefile.AMIGA",
                "lib/Makefile.AMIGA_AROS",
                "lib/Makefile.AMIGA_OS3",
                "lib/Makefile.PS3_PPU",
                "lib/ps2",
            ],
            sources: [
                "lib",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("include/apple"),
                .headerSearchPath("include/smb2"),
                .headerSearchPath("lib"),
                .define("_U_", to: "__attribute__((unused))"),
                .define("HAVE_CONFIG_H", to: "1"),
            ]
        ),
    ]
)
