import Foundation

public struct DiffLine: Hashable, Sendable {
    public enum Kind: Sendable { case header, added, removed, context }
    public let kind: Kind
    public let text: String
}

public struct DiffSection: Identifiable, Sendable {
    public let title: String
    public let lines: [DiffLine]
    public var id: String { title }
}

public enum DiffPreview: Sendable {
    case text([DiffSection])
    case binary
    case tooLarge
    case unavailable(String)
}

public extension GitRepository {
    static let previewByteLimit = 1_000_000

    func diffPreview(path: String) throws -> DiffPreview {
        try validate(paths: [path])
        let state = try status()
        guard let file = state.files.first(where: { $0.path == path }) else { return .unavailable("文件状态已变化，请刷新后重试。") }
        let url = root.appendingPathComponent(path)
        if file.isUntracked {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.intValue else { return .unavailable("文件已不存在。") }
            guard size <= Self.previewByteLimit else { return .tooLarge }
            guard let data = try? Data(contentsOf: url), !data.contains(0), let text = String(data: data, encoding: .utf8) else { return .binary }
            return .text([DiffSection(title: "新增文件", lines: text.components(separatedBy: "\n").map { DiffLine(kind: .added, text: $0) })])
        }
        let stagedStat = try git.require(["diff", "--cached", "--numstat", "--no-ext-diff", "--", path], at: root).output
        let workingStat = try git.require(["diff", "--numstat", "--no-ext-diff", "--", path], at: root).output
        if [stagedStat, workingStat].contains(where: { $0.contains("-\t-") }) { return .binary }
        let staged = try git.require(["diff", "--cached", "--no-ext-diff", "--no-color", "--", path], at: root).output
        let working = try git.require(["diff", "--no-ext-diff", "--no-color", "--", path], at: root).output
        guard staged.utf8.count + working.utf8.count <= Self.previewByteLimit else { return .tooLarge }
        var sections: [DiffSection] = []
        if !staged.isEmpty { sections.append(DiffSection(title: "已暂存", lines: Self.parseDiff(staged))) }
        if !working.isEmpty { sections.append(DiffSection(title: "未暂存", lines: Self.parseDiff(working))) }
        guard !sections.isEmpty else { return .unavailable("没有可显示的差异。") }
        return .text(sections)
    }

    static func parseDiff(_ text: String) -> [DiffLine] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { line in
            let kind: DiffLine.Kind
            if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                || line.hasPrefix("@@") || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
                || line.hasPrefix("old mode") || line.hasPrefix("new mode") || line.hasPrefix("similarity index")
                || line.hasPrefix("rename from") || line.hasPrefix("rename to") || line.hasPrefix("Binary files") {
                kind = .header
            } else if line.hasPrefix("+") { kind = .added }
            else if line.hasPrefix("-") { kind = .removed }
            else { kind = .context }
            return DiffLine(kind: kind, text: line)
        }
    }
}
