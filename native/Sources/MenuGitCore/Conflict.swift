import Foundation

public enum ConflictChoice: String, Sendable { case local, incoming, both }
public enum ConflictKind: Sendable { case text, binary, unsupported }
public struct ConflictBlock: Sendable {
    public let local: String
    public let incoming: String
}
public struct ConflictFileSummary: Sendable {
    public let path: String
    public let kind: ConflictKind
    public let unresolvedBlocks: Int
}
public struct ConflictDocument: Sendable {
    public let path: String
    public let kind: ConflictKind
    public let original: Data
    public let localVersion: Data
    public let incomingVersion: Data
    public let blocks: [ConflictBlock]
    public let localStartLines: [Int]
    public let incomingStartLines: [Int]
    public let sections: [[String]]
    fileprivate let localLines: [[String]]
    fileprivate let incomingLines: [[String]]
    public let reason: String

    public func result(choices: [ConflictChoice?]) throws -> String {
        guard kind == .text, choices.count == blocks.count, choices.allSatisfy({ $0 != nil }) else { throw GitFailure("请先处理此文件的全部冲突块。") }
        var lines = sections[0]
        for i in blocks.indices {
            switch choices[i]! { case .local: lines += localLines[i]; case .incoming: lines += incomingLines[i]; case .both: lines += localLines[i] + incomingLines[i] }
            lines += sections[i + 1]
        }
        return lines.joined(separator: "\n")
    }

    /// Lines immediately before and after the conflict block, shared by both sides.
    public func context(around index: Int) -> (before: String, after: String) {
        guard blocks.indices.contains(index) else { return ("", "") }
        return (sections[index].joined(separator: "\n"), sections[index + 1].joined(separator: "\n"))
    }
}

public extension GitRepository {
    func conflictDocument(path: String) throws -> ConflictDocument {
        try validate(paths: [path])
        let state = try status()
        guard state.conflictedOperation != nil, state.files.contains(where: { $0.path == path && $0.hasConflict }) else { throw GitFailure("文件冲突状态已变化，请刷新。") }
        let entries = try git.require(["ls-files", "--unmerged", "-z", "--", path], at: root).output
        let entryLines = entries.split(separator: "\0")
        let stages = entryLines.compactMap { line -> (String, Int)? in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[1] == Substring(path) else { return nil }
            let meta = fields[0].split(separator: " ")
            guard meta.count == 3, let stage = Int(meta[2]) else { return nil }
            return (String(meta[0]), stage)
        }
        let modes = stages.filter { $0.1 == 2 || $0.1 == 3 }.map(\.0)
        let fileURL = root.appendingPathComponent(path)
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        let data = exists ? (try Data(contentsOf: fileURL)) : Data()
        func unsupported(_ reason: String) -> ConflictDocument {
            ConflictDocument(path: path, kind: .unsupported, original: data, localVersion: Data(), incomingVersion: Data(), blocks: [], localStartLines: [], incomingStartLines: [], sections: [], localLines: [], incomingLines: [], reason: reason)
        }
        guard modes.count == 2, modes.allSatisfy({ $0 == "100644" || $0 == "100755" }), exists else { return unsupported("此冲突涉及删除、重命名或特殊文件类型，请使用外部工具处理。") }
        let ours = try git.require(["show", ":2:" + path], at: root).stdout
        let theirs = try git.require(["show", ":3:" + path], at: root).stdout
        let local = state.conflictedOperation == "rebase" ? theirs : ours
        let incoming = state.conflictedOperation == "rebase" ? ours : theirs
        if data.contains(0) || String(data: data, encoding: .utf8) == nil || ours.contains(0) || theirs.contains(0) {
            return ConflictDocument(path: path, kind: .binary, original: data, localVersion: local, incomingVersion: incoming, blocks: [], localStartLines: [], incomingStartLines: [], sections: [], localLines: [], incomingLines: [], reason: "二进制文件只能选择整份版本。")
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        func marker(_ line: String, _ prefix: String) -> Bool { let s = line.trimmingCharacters(in: .newlines); return s == prefix || s.hasPrefix(prefix + " ") }
        var sections: [[String]] = [[]], oursBlocks: [[String]] = [], theirsBlocks: [[String]] = []
        var index = 0
        while index < lines.count {
            if !marker(lines[index], "<<<<<<<") { sections[sections.count - 1].append(lines[index]); index += 1; continue }
            index += 1; var first: [String] = [], second: [String] = []
            while index < lines.count && !marker(lines[index], "=======") && !marker(lines[index], "|||||||") { first.append(lines[index]); index += 1 }
            if index < lines.count && marker(lines[index], "|||||||") { index += 1; while index < lines.count && !marker(lines[index], "=======") { index += 1 } }
            guard index < lines.count && marker(lines[index], "=======") else { return unsupported("无法解析此文件的冲突标记，请使用外部工具处理。") }
            index += 1
            while index < lines.count && !marker(lines[index], ">>>>>>>") { second.append(lines[index]); index += 1 }
            guard index < lines.count else { return unsupported("无法解析此文件的冲突标记，请使用外部工具处理。") }
            index += 1; oursBlocks.append(first); theirsBlocks.append(second); sections.append([])
        }
        guard !oursBlocks.isEmpty else { return unsupported("此文件没有可识别的文本冲突块，请使用外部工具处理。") }
        let localBlocks = state.conflictedOperation == "rebase" ? theirsBlocks : oursBlocks
        let incomingBlocks = state.conflictedOperation == "rebase" ? oursBlocks : theirsBlocks
        let blocks = zip(localBlocks, incomingBlocks).map { ConflictBlock(local: $0.joined(separator: "\n"), incoming: $1.joined(separator: "\n")) }
        var localStartLines: [Int] = [], incomingStartLines: [Int] = []
        var localLine = sections[0].count, incomingLine = sections[0].count
        for i in blocks.indices {
            localStartLines.append(localLine + 1)
            incomingStartLines.append(incomingLine + 1)
            localLine += localBlocks[i].count + sections[i + 1].count
            incomingLine += incomingBlocks[i].count + sections[i + 1].count
        }
        return ConflictDocument(path: path, kind: .text, original: data, localVersion: local, incomingVersion: incoming, blocks: blocks, localStartLines: localStartLines, incomingStartLines: incomingStartLines, sections: sections, localLines: localBlocks, incomingLines: incomingBlocks, reason: "")
    }

    func conflictSummaries() throws -> [ConflictFileSummary] {
        let state = try status()
        return state.files.filter(\.hasConflict).map { file in
            let url = root.appendingPathComponent(file.path)
            guard let data = try? Data(contentsOf: url) else { return ConflictFileSummary(path: file.path, kind: .unsupported, unresolvedBlocks: 0) }
            if data.contains(0) || String(data: data, encoding: .utf8) == nil {
                return ConflictFileSummary(path: file.path, kind: .binary, unresolvedBlocks: 0)
            }
            let blocks = String(decoding: data, as: UTF8.self).components(separatedBy: "\n").filter { $0.hasPrefix("<<<<<<< ") }.count
            return ConflictFileSummary(path: file.path, kind: blocks > 0 ? .text : .unsupported, unresolvedBlocks: blocks)
        }
    }

    func saveConflict(_ document: ConflictDocument, result: Data) throws {
        try validate(paths: [document.path])
        let state = try status()
        guard state.conflictedOperation != nil, state.files.contains(where: { $0.path == document.path && $0.hasConflict }) else { throw GitFailure("文件冲突状态已变化，请刷新。") }
        let url = root.appendingPathComponent(document.path)
        guard try Data(contentsOf: url) == document.original else { throw GitFailure("文件已被其他程序修改，请重新打开冲突后处理。") }
        if document.kind == .text {
            guard let text = String(data: result, encoding: .utf8), !text.components(separatedBy: "\n").contains(where: { $0.hasPrefix("<<<<<<< ") || $0 == "=======" || $0.hasPrefix(">>>>>>> ") }) else { throw GitFailure("请先删除全部冲突标记。") }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw GitFailure("不能自动处理特殊文件。") }
        try result.write(to: url, options: .atomic)
        if let permissions = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        guard try Data(contentsOf: url) == result else { throw GitFailure("文件被其他程序修改，请检查后重试。") }
        try git.require(["add", "--", document.path], at: root)
    }

    func continueConflict() throws {
        let state = try status()
        guard let operation = state.conflictedOperation else { throw GitFailure("当前没有进行中的合并或变基。") }
        guard !state.files.contains(where: \.hasConflict) else { throw GitFailure("请先解决所有冲突文件。") }
        // Use Git's existing commit message without opening a terminal editor.
        let result = try git.run([operation, "--continue"], at: root, environment: ["GIT_EDITOR": ":"])
        guard result.status == 0 else { throw GitFailure("继续操作未完成，请检查仓库状态。", detail: result.error + result.output) }
    }

    func abortConflict() throws {
        let state = try status()
        guard let operation = state.conflictedOperation else { throw GitFailure("当前没有进行中的合并或变基。") }
        try git.require([operation, "--abort"], at: root)
    }
}
