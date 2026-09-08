import Foundation

/// Built up from `upload-batch` output as it streams. The Go side prints one
/// line per asset (`[12/500] uploaded IMG_1234.HEIC (original) -> linkID`),
/// which is enough to drive both a progress bar and live counters without
/// any extra IPC or polling of the database.
struct UploadProgress: Equatable {
    var completed = 0
    var total = 0
    var uploaded = 0
    var skipped = 0
    var failed = 0
    var lastMessage = "Starting…"

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }

    /// What a given output line says happened to one asset. Only the three
    /// terminal outcomes are tallied -- notably, the "duplicate check
    /// failed, uploading anyway" warning carries the same counter as the
    /// upload line that follows it, so counting every line with a counter
    /// would double-count that asset.
    enum Outcome {
        case uploaded
        case skipped
        case failed
        case other
    }

    static func classify(_ line: String) -> Outcome {
        if line.contains("warning:") { return .other }
        if line.contains("] uploaded ") { return .uploaded }
        if line.contains("already on Proton, skipping") { return .skipped }
        if line.contains("] FAILED ") { return .failed }
        return .other
    }

    /// Matches a leading "[<done>/<total>]" counter, ignoring lines that
    /// don't carry one (the final summary, stray log output).
    static func parseCounter(from line: String) -> (completed: Int, total: Int)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let inner = line[line.index(after: line.startIndex)..<close]
        let parts = inner.split(separator: "/")
        guard parts.count == 2,
              let done = Int(parts[0]),
              let total = Int(parts[1])
        else { return nil }
        return (done, total)
    }

    mutating func apply(line: String) {
        if let counter = UploadProgress.parseCounter(from: line) {
            completed = counter.completed
            total = counter.total
        }
        switch UploadProgress.classify(line) {
        case .uploaded: uploaded += 1
        case .skipped: skipped += 1
        case .failed: failed += 1
        case .other: break
        }
        lastMessage = line
    }

    /// Short form for the menu bar, where space is tight.
    var menuBarLabel: String {
        total > 0 ? "\(completed)/\(total)" : "…"
    }
}
