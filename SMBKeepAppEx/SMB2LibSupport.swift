/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Helpers for using libsmb2 (import SMB2) from the passthrough file system.
*/

import Foundation
import SMB2

enum SMB2LibSupport {

    static func posixError(fromContext context: UnsafeMutablePointer<smb2_context>?, code: Int32) -> POSIXError {
        let errnoCode = code < 0 ? POSIXErrorCode(rawValue: -code) : POSIXErrorCode(rawValue: code)
        let message = context.flatMap { smb2_get_error($0) }.map { String(cString: $0) }
        return POSIXError(errnoCode ?? .EIO, userInfo: message.map { [NSLocalizedDescriptionKey: $0] } ?? [:])
    }

    static func requireContext(_ context: UnsafeMutablePointer<smb2_context>?) throws
        -> UnsafeMutablePointer<smb2_context> {
        guard let context else {
            throw POSIXError(.ENOTCONN)
        }
        return context
    }

    static func check(_ result: Int32, context: UnsafeMutablePointer<smb2_context>?) throws {
        guard result >= 0 else {
            throw posixError(fromContext: context, code: result)
        }
    }

    static func serverAddress(from url: URL) -> String {
        guard let host = url.host else { return "" }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }
}

extension String {
    var smbTrimmedPath: String {
        trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
    }

    func smbAppendingPath(_ component: String, isDirectory: Bool = false) -> String {
        var result = self
        if result.hasSuffix("/") || result.hasSuffix("\\") {
            result.removeLast()
        }
        result = self.isEmpty ? component.smbTrimmedPath : result + "/" + component.smbTrimmedPath
        if isDirectory, !result.hasSuffix("/") {
            result += "/"
        }
        return result
    }
}

extension smb2_stat_64 {
    struct ResourceType: Hashable {
        var rawValue: UInt32
        static let file = Self(rawValue: UInt32(SMB2_TYPE_FILE))
        static let directory = Self(rawValue: UInt32(SMB2_TYPE_DIRECTORY))
        static let link = Self(rawValue: UInt32(SMB2_TYPE_LINK))

        var urlResourceType: URLFileResourceType {
            switch self {
            case .directory: return .directory
            case .file: return .regular
            case .link: return .symbolicLink
            default: return .unknown
            }
        }
    }

    var resourceType: ResourceType {
        ResourceType(rawValue: smb2_type)
    }

    var isDirectory: Bool {
        resourceType == .directory
    }

    func resourceDictionary(path: String, name: String) -> [URLResourceKey: any Sendable] {
        var result = [URLResourceKey: any Sendable]()
        result[.nameKey] = name
        result[.pathKey] = isDirectory ? path.smbAppendingPath(name, isDirectory: true) : path.smbAppendingPath(name)
        result[.fileSizeKey] = NSNumber(value: smb2_size)
        result[.linkCountKey] = NSNumber(value: smb2_nlink)
        result[.documentIdentifierKey] = NSNumber(value: smb2_ino)
        result[.fileResourceTypeKey] = resourceType.urlResourceType
        result[.isDirectoryKey] = NSNumber(value: isDirectory)
        result[.isRegularFileKey] = NSNumber(value: resourceType == .file)
        result[.isSymbolicLinkKey] = NSNumber(value: resourceType == .link)
        result[.contentModificationDateKey] = Date(timespecSec: Int(smb2_mtime), nsec: Int(smb2_mtime_nsec))
        result[.attributeModificationDateKey] = Date(timespecSec: Int(smb2_ctime), nsec: Int(smb2_ctime_nsec))
        result[.contentAccessDateKey] = Date(timespecSec: Int(smb2_atime), nsec: Int(smb2_atime_nsec))
        result[.creationDateKey] = Date(timespecSec: Int(smb2_btime), nsec: Int(smb2_btime_nsec))
        return result
    }
}

private extension Date {
    init(timespecSec sec: Int, nsec: Int) {
        self.init(timeIntervalSince1970: TimeInterval(sec) + TimeInterval(nsec) / 1_000_000_000)
    }
}
