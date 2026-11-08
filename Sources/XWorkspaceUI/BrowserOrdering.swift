import Foundation

/// Sorting and searching over precomputed name bytes. Sorting runs once per
/// listing; filtering is a single linear pass over the already sorted order, so
/// typing a query never re-sorts.
public enum BrowserOrdering {
    /// Lowercases ASCII letters and leaves every other byte as is.
    static func foldedBytes(_ string: String) -> ContiguousArray<UInt8> {
        var bytes = ContiguousArray(string.utf8)
        for index in bytes.indices where bytes[index] >= 0x41 && bytes[index] <= 0x5A { bytes[index] |= 0x20 }
        return bytes
    }

    /// Orders folders first, then names with digit runs compared by value ("2" < "10").
    static func precedes(_ a: BrowserItem, _ b: BrowserItem) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return naturalLess(a.key, b.key)
    }

    static func naturalLess(_ a: ContiguousArray<UInt8>, _ b: ContiguousArray<UInt8>) -> Bool {
        a.withUnsafeBufferPointer { a in b.withUnsafeBufferPointer { b in
            var i = 0, j = 0
            while i < a.count, j < b.count {
                let x = a[i], y = b[j]
                if isDigit(x), isDigit(y) {
                    // Skip leading zeros, then the longer run is the larger number.
                    var si = i, sj = j
                    while si < a.count - 1, a[si] == 0x30, isDigit(a[si + 1]) { si += 1 }
                    while sj < b.count - 1, b[sj] == 0x30, isDigit(b[sj + 1]) { sj += 1 }
                    var ei = si, ej = sj
                    while ei < a.count, isDigit(a[ei]) { ei += 1 }
                    while ej < b.count, isDigit(b[ej]) { ej += 1 }
                    let li = ei - si, lj = ej - sj
                    if li != lj { return li < lj }
                    var k = 0
                    while k < li {
                        if a[si + k] != b[sj + k] { return a[si + k] < b[sj + k] }
                        k += 1
                    }
                    i = ei; j = ej
                } else {
                    if x != y { return x < y }
                    i += 1; j += 1
                }
            }
            return (a.count - i) < (b.count - j)
        } }
    }

    @inline(__always) private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    /// The items in display order.
    ///
    /// Every name is turned into a byte string whose plain lexicographic order *is*
    /// the display order (folders first, digit runs by value), packed into one arena.
    /// Sorting then compares an 8-byte prefix as a single integer and only falls back
    /// to the full bytes on a tie, with no per-item allocation and no Unicode tables.
    public static func sorted(_ items: [BrowserItem]) -> [BrowserItem] {
        let count = items.count
        guard count > 1 else { return items }
        var arena = [UInt8]()
        arena.reserveCapacity(items.reduce(0) { $0 + $1.key.count + 3 })
        var records = [SortRecord]()
        records.reserveCapacity(count)
        for index in 0..<count {
            let start = arena.count
            arena.append(items[index].isDirectory ? 0 : 1)
            appendNaturalKey(items[index].key, to: &arena)
            var prefix: UInt64 = 0
            for k in 0..<8 {
                prefix <<= 8
                if start + k < arena.count { prefix |= UInt64(arena[start + k]) }
            }
            records.append(SortRecord(prefix: prefix, start: Int32(start), end: Int32(arena.count), index: Int32(index)))
        }
        arena.withUnsafeBufferPointer { bytes in
            records.sort { a, b in
                if a.prefix != b.prefix { return a.prefix < b.prefix }
                let la = Int(a.end - a.start), lb = Int(b.end - b.start)
                let common = min(la, lb)
                if common > 8 {
                    let order = memcmp(bytes.baseAddress! + Int(a.start) + 8, bytes.baseAddress! + Int(b.start) + 8, common - 8)
                    if order != 0 { return order < 0 }
                }
                return la != lb ? la < lb : a.index < b.index
            }
        }
        return records.map { items[Int($0.index)] }
    }

    private struct SortRecord {
        var prefix: UInt64
        var start: Int32
        var end: Int32
        var index: Int32
    }

    /// Digit runs become `0x30, length, digits-without-leading-zeros`, so a longer
    /// number sorts after a shorter one under plain byte comparison and every other
    /// byte keeps its place relative to digits.
    static func appendNaturalKey(_ key: ContiguousArray<UInt8>, to out: inout [UInt8]) {
        var i = 0
        let n = key.count
        while i < n {
            let byte = key[i]
            if isDigit(byte) {
                var end = i
                while end < n, isDigit(key[end]) { end += 1 }
                var first = i
                while first < end - 1, key[first] == 0x30 { first += 1 }
                let length = end - first
                out.append(0x30)
                out.append(UInt8(min(length, 255)))
                out.append(contentsOf: key[first..<end])
                i = end
            } else {
                out.append(byte)
                i += 1
            }
        }
    }

    /// Indices of `items` (already sorted) that pass `filter` and contain `query`.
    public static func visible(in items: [BrowserItem], filter: BrowserFilter, query: String) -> [Int32] {
        let needle = foldedBytes(query.trimmingCharacters(in: .whitespaces))
        var result: [Int32] = []
        result.reserveCapacity(items.count)
        let unfiltered = filter == .all
        for index in items.indices {
            let item = items[index]
            if !unfiltered, !filter.admits(item) { continue }
            if !needle.isEmpty, !contains(item.key, needle) { continue }
            result.append(Int32(index))
        }
        return result
    }

    static func contains(_ haystack: ContiguousArray<UInt8>, _ needle: ContiguousArray<UInt8>) -> Bool {
        let n = needle.count
        if n == 0 { return true }
        if n > haystack.count { return false }
        return haystack.withUnsafeBufferPointer { h in needle.withUnsafeBufferPointer { nd in
            let first = nd[0]
            var i = 0
            let last = h.count - n
            while i <= last {
                if h[i] == first {
                    var k = 1
                    while k < n, h[i + k] == nd[k] { k += 1 }
                    if k == n { return true }
                }
                i += 1
            }
            return false
        } }
    }

    /// The straightforward Foundation version, kept as the benchmark baseline and as the oracle in tests.
    public static func referenceSorted(_ items: [BrowserItem]) -> [BrowserItem] {
        items.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func referenceVisible(in items: [BrowserItem], query: String) -> [Int32] {
        items.indices.compactMap { index in
            query.isEmpty || items[index].name.localizedCaseInsensitiveContains(query) ? Int32(index) : nil
        }
    }
}
