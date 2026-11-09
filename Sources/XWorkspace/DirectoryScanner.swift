import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Lists a directory without building a URL per entry. Symlinks and anything that is not a regular file
/// or a directory are skipped, exactly as `Workspace.list` has always done.
///
/// On Apple platforms one `getattrlistbulk` call returns the name, type, size and modification time of
/// many entries at once, where `readdir` + `fstatat` costs a system call per entry. Where that call is not
/// supported by the file system, and on other platforms, the `readdir` path is used.
enum DirectoryScanner {
    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    static let isAvailable = true

    /// Calls `make(name, isDirectory, size, modified)` for each entry and collects the results.
    /// `size` is 0 for a directory.
    static func scan<T>(_ directory: URL, _ make: (String, Bool, Int64, Date?) -> T) throws -> [T] {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        #if canImport(Darwin)
        if let result = try scanInBulk(descriptor, make) {
            close(descriptor)
            return result
        }
        #endif
        return try scanWithReaddir(descriptor, make)   // takes over `descriptor`
    }

    /// The modification time of a path in nanoseconds since 1970 and whether it is a directory; nil if it cannot be read.
    static func modification(of path: String) -> (nanoseconds: Int64, isDirectory: Bool)? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        #if canImport(Darwin)
        let time = status.st_mtimespec
        #else
        let time = status.st_mtim
        #endif
        return (Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec), status.st_mode & S_IFMT == S_IFDIR)
    }

    /// The `readdir` path on its own, so a test can compare it with the bulk one.
    static func scanWithReaddirForTesting<T>(_ directory: URL, _ make: (String, Bool, Int64, Date?) -> T) throws -> [T] {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try scanWithReaddir(descriptor, make)
    }

    private static func scanWithReaddir<T>(_ descriptor: Int32, _ make: (String, Bool, Int64, Date?) -> T) throws -> [T] {
        guard let stream = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        defer { closedir(stream) }   // also closes `descriptor`

        var result: [T] = []
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
            result.append(make(name, type == S_IFDIR, type == S_IFREG ? Int64(status.st_size) : 0, Date(timeIntervalSince1970: seconds)))
        }
        return result
    }

    #if canImport(Darwin)
    /// nil when the file system does not answer `getattrlistbulk`; the descriptor is left open for the fallback.
    private static func scanInBulk<T>(_ descriptor: Int32, _ make: (String, Bool, Int64, Date?) -> T) throws -> [T]? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE) | attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME)
        request.fileattr = attrgroup_t(truncatingIfNeeded: ATTR_FILE_DATALENGTH)

        let capacity = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }

        var result: [T] = []
        var first = true
        while true {
            let count = getattrlistbulk(descriptor, &request, buffer, capacity, 0)
            if count < 0 {
                if first && (errno == ENOTSUP || errno == EINVAL) { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { return result }
            first = false

            var record = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(record.loadUnaligned(as: UInt32.self))
                defer { record += length }
                // Packed in the order of the bits: returned set, name, object type, modification time, data length.
                var cursor = record + 4
                let returned = cursor.loadUnaligned(as: attribute_set_t.self)
                cursor += MemoryLayout<attribute_set_t>.size
                guard returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME) != 0,
                      returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE) != 0 else { continue }
                let reference = cursor.loadUnaligned(as: attrreference_t.self)
                let nameStart = cursor + Int(reference.attr_dataoffset)
                cursor += MemoryLayout<attrreference_t>.size
                let type = cursor.loadUnaligned(as: UInt32.self)
                cursor += 4
                guard type == UInt32(VREG.rawValue) || type == UInt32(VDIR.rawValue) else { continue }
                var modified: Date?
                if returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME) != 0 {
                    let time = cursor.loadUnaligned(as: timespec.self)
                    cursor += MemoryLayout<timespec>.size
                    modified = Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
                }
                var size: Int64 = 0
                if type == UInt32(VREG.rawValue), returned.fileattr & attrgroup_t(truncatingIfNeeded: ATTR_FILE_DATALENGTH) != 0 {
                    size = cursor.loadUnaligned(as: Int64.self)
                }
                let name = String(cString: nameStart.assumingMemoryBound(to: CChar.self))
                result.append(make(name, type == UInt32(VDIR.rawValue), size, modified))
            }
        }
    }
    #endif
    #else
    static let isAvailable = false
    static func scan<T>(_ directory: URL, _ make: (String, Bool, Int64, Date?) -> T) throws -> [T] { [] }
    static func scanWithReaddirForTesting<T>(_ directory: URL, _ make: (String, Bool, Int64, Date?) -> T) throws -> [T] { [] }
    static func modification(of path: String) -> (nanoseconds: Int64, isDirectory: Bool)? { nil }
    #endif
}
