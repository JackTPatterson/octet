import Foundation

/// Resident memory is summed once per process, even when roots overlap.
enum ResourceFootprint {
    struct Row: Equatable {
        let pid: Int
        let parent: Int
        let bytes: UInt64
    }

    static func parse(_ output: String) -> [Row] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int(fields[0]), let parent = Int(fields[1]),
                  let kb = UInt64(fields[2]), kb <= UInt64.max / 1024 else { return nil }
            return Row(pid: pid, parent: parent, bytes: kb * 1024)
        }
    }

    static func total(_ rows: [Row], roots: Set<Int>) -> UInt64 {
        let children = Dictionary(grouping: rows, by: \.parent)
        let indexed = Dictionary(rows.map { ($0.pid, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        var pending = Array(roots), visited = Set<Int>(), bytes: UInt64 = 0
        while let pid = pending.popLast() {
            guard visited.insert(pid).inserted else { continue }
            bytes += indexed[pid] ?? 0
            pending += (children[pid] ?? []).map(\.pid)
        }
        return bytes
    }

    static func label(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.1f MB", mb)
    }
}
