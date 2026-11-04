import Foundation

/// How a command-line tool ended and what it printed on standard output.
struct ProcessResult: Equatable {
    enum Ending: Equatable {
        case exited(Int32)
        case timedOut
        case failedToLaunch
    }

    var ending: Ending
    var output: Data
}

/// Runs a command-line tool. Behind a protocol so tests never reach the real Keychain item.
protocol ProcessRunning {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async -> ProcessResult
}

/// Runs the tool off the main thread; one still running at the timeout is terminated.
/// Standard error and standard input are the null device. The output is returned, never logged.
struct ProcessRunner: ProcessRunning {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.runBlocking(executable: executable, arguments: arguments, timeout: timeout))
            }
        }
    }

    private static func runBlocking(executable: URL, arguments: [String], timeout: TimeInterval) -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ProcessResult(ending: .failedToLaunch, output: Data())
        }

        let timedOut = Flag()
        let deadline = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()   // ends when the tool exits or is terminated
        process.waitUntilExit()
        deadline.cancel()

        if timedOut.isSet { return ProcessResult(ending: .timedOut, output: Data()) }
        return ProcessResult(ending: .exited(process.terminationStatus), output: data)
    }

    /// Set from the deadline's queue, read after the process ended.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }
}
