import Foundation

public struct GitResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var error: String { String(decoding: stderr, as: UTF8.self) }
}

public struct GitFailure: LocalizedError, Sendable {
    public let summary: String
    public let detail: String
    public var errorDescription: String? { summary }
    public init(_ summary: String, detail: String = "") { self.summary = summary; self.detail = detail }
}

/// Execute Git without a shell. Temporary output files avoid pipe buffer deadlocks.
public struct GitRunner: Sendable {
    public let executable: URL
    public let extraEnvironment: [String: String]

    public init(executable: URL? = nil, extraEnvironment: [String: String] = [:]) {
        self.extraEnvironment = extraEnvironment
        if let executable { self.executable = executable; return }
        let env = ProcessInfo.processInfo.environment
        let search = (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let path = search.map { ($0 as NSString).appendingPathComponent("git") }
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
        self.executable = URL(fileURLWithPath: path)
    }

    private func resolvedEnvironment(_ overrides: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["GIT_TERMINAL_PROMPT"] = "0"
        extraEnvironment.forEach { env[$0.key] = $0.value }
        overrides.forEach { env[$0.key] = $0.value }
        return env
    }

    public func run(_ arguments: [String], at directory: URL, environment: [String: String] = [:]) throws -> GitResult {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("MenuGit-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: folder) }
        let outURL = folder.appendingPathComponent("stdout")
        let errURL = folder.appendingPathComponent("stderr")
        guard manager.createFile(atPath: outURL.path, contents: nil), manager.createFile(atPath: errURL.path, contents: nil) else {
            throw GitFailure("无法创建 Git 输出文件")
        }
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.arguments = ["--literal-pathspecs"] + arguments
        process.environment = resolvedEnvironment(environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { throw GitFailure("无法启动 Git，请检查系统 Git 是否可用。", detail: error.localizedDescription) }
        process.waitUntilExit()
        try out.synchronize(); try err.synchronize()
        return GitResult(status: process.terminationStatus, stdout: try Data(contentsOf: outURL), stderr: try Data(contentsOf: errURL))
    }

    @discardableResult
    public func require(_ arguments: [String], at directory: URL, environment: [String: String] = [:]) throws -> GitResult {
        let result = try run(arguments, at: directory, environment: environment)
        guard result.status == 0 else {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitFailure("Git 操作未完成", detail: message.isEmpty ? result.output : message)
        }
        return result
    }

    public func version() -> String {
        (try? run(["--version"], at: FileManager.default.temporaryDirectory))?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "无法读取 Git 版本"
    }

    /// Starts a long-running Git command and reports merged stdout/stderr lines as they arrive.
    /// The caller owns the returned task and must call `wait()`; `cancel()` terminates the process.
    public func startStreaming(_ arguments: [String], at directory: URL, environment: [String: String] = [:], onOutput: @escaping @Sendable (String) -> Void) throws -> StreamingGitTask {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.arguments = ["--literal-pathspecs"] + arguments
        process.environment = resolvedEnvironment(environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { throw GitFailure("无法启动 Git，请检查系统 Git 是否可用。", detail: error.localizedDescription) }
        let task = StreamingGitTask(process: process)
        let handle = pipe.fileHandleForReading
        Thread.detachNewThread {
            var buffer = Data()
            func flush() {
                while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let line = String(decoding: buffer[buffer.startIndex..<index], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                    buffer.removeSubrange(buffer.startIndex...index)
                    if !line.isEmpty { onOutput(line) }
                }
            }
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                flush()
            }
            if let last = String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespaces), !last.isEmpty { onOutput(last) }
            try? handle.close()
        }
        return task
    }
}

public final class StreamingGitTask: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var cancelled = false
    init(process: Process) { self.process = process }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }

    public func wait() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }
}
