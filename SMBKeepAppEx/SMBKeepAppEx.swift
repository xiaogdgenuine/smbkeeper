/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
App 扩展对一元（unary）文件系统扩展协议的实现，
声明提供文件系统具体实现的自定义类。
*/

import Foundation
import FSKit

@main
struct SMBKeepAppEx: UnaryFileSystemExtension {

    typealias FileSystem = FSUnaryFileSystem & FSUnaryFileSystemOperations

    init() {
        // libsmb2 直接写 TCP socket。如果 SMB 连接断开后我们又往这个已死的 socket 写，
        // 内核会触发 SIGPIPE，其默认行为会杀掉本扩展进程（退出码 13，且不产生崩溃报告），
        // 进而导致 FSKit 强制卸载卷。这里忽略该信号，让失败的调用返回 EPIPE，
        // 从而走我们自己的连接丢失/重连逻辑。
        signal(SIGPIPE, SIG_IGN)
    }

    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        SMBKeepFileSystem()
    }
}
