/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The app extension's conformance to the unary file system exension protocol,
 which declares the custom class that provides the file system implementation.
*/

import Foundation
import FSKit

@main
struct SMBKeepAppEx: UnaryFileSystemExtension {

    typealias FileSystem = FSUnaryFileSystem & FSUnaryFileSystemOperations

    init() {
        // libsmb2 writes directly to the TCP socket. If the SMB connection drops
        // and we then write to the dead socket, the kernel raises SIGPIPE, whose
        // default action kills this extension process (exit code 13, no crash report),
        // which in turn makes FSKit force-unmount the volume. Ignore it so the failing
        // call returns EPIPE instead, letting our connection-loss/reconnect logic run.
        signal(SIGPIPE, SIG_IGN)
    }

    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        SMBKeepFileSystem()
    }
}
