import Foundation
import Darwin

public enum OperationError: LocalizedError {
    case cancelled
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "操作已取消，源文件和已完成的结果已保留。"
        case .timedOut(let name): return "\(name) 执行超时，请检查设备连接后重试。"
        }
    }
}

public final class OperationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public let onProgress: @Sendable (String) -> Void

    public init(onProgress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onProgress = onProgress
    }

    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func checkCancellation() throws { if isCancelled { throw OperationError.cancelled } }
}

public protocol ProcessRunning {
    @discardableResult
    func run(executable: URL, arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String)
}

/// Drain both pipes while the process is running. Retain only a bounded tail of output.
public struct FoundationProcessRunner: ProcessRunning {
    private let timeout: TimeInterval
    private let control: OperationControl?
    private let outputLimit: Int

    public init(timeout: TimeInterval = 300, control: OperationControl? = nil, outputLimit: Int = 2 * 1024 * 1024) {
        self.timeout = timeout
        self.control = control
        self.outputLimit = max(1024, outputLimit)
    }

    public func run(executable: URL, arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try control?.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        for pipe in [out, err] {
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        defer {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
        }
        var stdout = Data(), stderr = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var failure: OperationError?
        var terminateAt: TimeInterval?
        while true {
            drain(out.fileHandleForReading.fileDescriptor, into: &stdout)
            drain(err.fileHandleForReading.fileDescriptor, into: &stderr)
            if ended.wait(timeout: .now() + 0.025) == .success { break }
            let now = ProcessInfo.processInfo.systemUptime
            if failure == nil, control?.isCancelled == true || now >= deadline {
                failure = control?.isCancelled == true ? .cancelled : .timedOut(executable.lastPathComponent)
                terminateAt = now
                if process.isRunning { process.terminate() }
            }
            if let terminateAt, now - terminateAt >= 1, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        drain(out.fileHandleForReading.fileDescriptor, into: &stdout)
        drain(err.fileHandleForReading.fileDescriptor, into: &stderr)
        process.waitUntilExit()
        if let failure { throw failure }
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }

    private func drain(_ fd: Int32, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        // Bound each pass so a busy stdout cannot starve stderr or cancellation.
        for _ in 0..<16 {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > outputLimit { data.removeFirst(data.count - outputLimit) }
        }
    }
}

public func runInBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result(catching: work))
        }
    }
}
