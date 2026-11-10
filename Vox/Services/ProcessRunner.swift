import Foundation
import Darwin

/// Bounded local tools with concurrent pipe draining. Cancellation and deadlines both
/// stop the child; failed/partial output is never treated as a transcription.
// One worker owns pipe/output operations; cancellation state and child lifetime use lock.
final class ProcessRunner: @unchecked Sendable {
    struct Output {
        let status: Int32
        let data: Data
        let stopped: Bool
    }
    private static let registryLock = NSLock()
    private static var shuttingDown = false
    private static var active: [UUID: ProcessRunner] = [:]

    /// App shutdown must stop tools from every caller, including Black Box reprocessing.
    static func cancelAll() {
        registryLock.lock()
        shuttingDown = true
        let runners = Array(active.values)
        registryLock.unlock()
        for runner in runners { runner.stop(immediately: true) }
    }

    private let lock = NSLock()
    private let process = Process()
    private var stopped = false

    private func stop(immediately: Bool = false) {
        lock.lock()
        stopped = true
        if process.isRunning {
            if immediately { kill(process.processIdentifier, SIGKILL) } else { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock()
                defer { lock.unlock() }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        lock.unlock()
    }

    static func run(executable: String, arguments: [String], timeout: TimeInterval) async -> Output {
        let runner = ProcessRunner()
        let id = UUID()
        register(runner, id: id)
        defer { unregister(id) }
        return await withTaskCancellationHandler(operation: {
            await runner.execute(executable: executable, arguments: arguments, timeout: timeout)
        }, onCancel: { runner.stop() })
    }

    private static func register(_ runner: ProcessRunner, id: UUID) {
        registryLock.lock()
        let reject = shuttingDown
        if !reject { active[id] = runner }
        registryLock.unlock()
        if reject { runner.stop(immediately: true) }
    }

    private static func unregister(_ id: UUID) {
        registryLock.lock()
        active[id] = nil
        registryLock.unlock()
    }

    private func execute(executable: String, arguments: [String], timeout: TimeInterval) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let stdout = Pipe(), stderr = Pipe()
                lock.lock()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = stdout
                process.standardError = stderr
                guard !stopped else {
                    lock.unlock()
                    continuation.resume(returning: Output(status: -1, data: Data(), stopped: true))
                    return
                }
                do { try process.run() }
                catch {
                    lock.unlock()
                    continuation.resume(returning: Output(status: -1, data: Data(), stopped: false))
                    return
                }
                lock.unlock()
                let timer = DispatchWorkItem { [self] in stop() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let drains = DispatchGroup()
                drains.enter()
                DispatchQueue.global().async {
                    while !stderr.fileHandleForReading.availableData.isEmpty {}
                    drains.leave()
                }
                // Drain stdout while the child runs, not after waitUntilExit (pipe capacity is finite).
                var output = Data()
                while true {
                    let chunk = stdout.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    if output.count + chunk.count <= 32 * 1024 * 1024 { output.append(chunk) }
                    else { stop() }
                }
                process.waitUntilExit()
                drains.wait()
                timer.cancel()
                lock.lock()
                let wasStopped = stopped
                lock.unlock()
                continuation.resume(returning: Output(status: process.terminationStatus, data: output, stopped: wasStopped))
            }
        }
    }
}
