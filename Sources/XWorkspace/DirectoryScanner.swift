import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One directory entry as the scanner saw it.
struct ScannedEntry {
    var name: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date?
}

/// Lists a directory with `readdir` + `fstatat`: one system call per entry, no URL
/// objects. Symlinks and anything that is not a regular file or a directory are skipped,
/// exactly as `Workspace.list` has always done.
enum DirectoryScanner {
    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    static let isAvailable = true

    static func scan(_ directory: URL) throws -> [ScannedEntry] {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard let stream = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        defer { closedir(stream) }   // also closes `descriptor`

        var result: [ScannedEntry] = []
        var status = stat()
        while let entry = readdir(stream) {
            let skip: Bool = withUnsafePointer(to: &entry.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: 1) { name in
                    name[0] == 0x2E && (name[1] == 0 || (name[1] == 0x2E && name[2] == 0))
                }
            }
            if skip { continue }
            let name: String = withUnsafePointer(to: &entry.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
            }
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let type = status.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else { continue }
            #if canImport(Darwin)
            let seconds = Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1e9
            #else
            let seconds = Double(status.st_mtim.tv_sec) + Double(status.st_mtim.tv_nsec) / 1e9
            #endif
            result.append(ScannedEntry(name: name, isDirectory: type == S_IFDIR,
                                       size: type == S_IFREG ? Int64(status.st_size) : 0,
                                       modified: Date(timeIntervalSince1970: seconds)))
        }
        return result
    }
    #else
    static let isAvailable = false
    static func scan(_ directory: URL) throws -> [ScannedEntry] { [] }
    #endif
}
