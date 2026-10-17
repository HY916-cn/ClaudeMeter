import Foundation
import Darwin

/// Runs only the installed Claude CLI's account-status and local /usage commands.
/// Calls are serialized by the service; all captures and lifetimes are bounded.
nonisolated final class ClaudeCLIClient: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProcess: Process?
    private var isCancelled = false
    static let maximumCaptureBytes = 256 * 1_024

    static var probeDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeMeter/CLI", isDirectory: true)
    }

    static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let fm = FileManager.default
        let direct = [home.appendingPathComponent(".local/bin/claude"),
                      URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                      URL(fileURLWithPath: "/usr/local/bin/claude"),
                      home.appendingPathComponent(".npm-global/bin/claude")]
        let nvm = (try? fm.contentsOfDirectory(at: home.appendingPathComponent(".nvm/versions/node"),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let versions = nvm.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
        }.map { $0.appendingPathComponent("bin/claude") }
        return (direct + versions).first { fm.isExecutableFile(atPath: $0.path) }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let process = activeProcess
        lock.unlock()
        if let process {
            Self.terminate(process, ownsGroup: getpgid(process.processIdentifier) == process.processIdentifier)
        }
    }

    private static func terminate(_ process: Process, ownsGroup: Bool) {
        let pid = process.processIdentifier
        if ownsGroup { kill(-pid, SIGTERM) }
        else if process.isRunning { process.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        while (ownsGroup ? kill(-pid, 0) == 0 : process.isRunning)
                && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        // A descendant can outlive the CLI leader; terminate the owned group even
        // after Foundation reports the leader's exit.
        if ownsGroup { kill(-pid, SIGKILL) }
        else if process.isRunning { kill(pid, SIGKILL) }
    }

    func fetch(onAccount: (ClaudeAuthStatus) -> Void) throws -> [CodexUsageWindow] {
        guard let executable = Self.locate() else { throw ClaudeCLIError.notInstalled }
        let directory = Self.probeDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = try authStatus(executable: executable, directory: directory)
        onAccount(account)
        guard account.loggedIn else { throw ClaudeCLIError.notLoggedIn }
        guard account.supportsUsage else { throw ClaudeCLIError.subscriptionRequired }
        let output = try capture(executable: executable, arguments: [
            "--safe-mode", "--ax-screen-reader", "--tools", "", "--strict-mcp-config",
            "--settings", #"{"disableAllHooks":true,"remoteControlAtStartup":false}"#, "/usage"
        ], directory: directory, usage: true, timeout: 20)
        let finalAccount = try authStatus(executable: executable, directory: directory)
        if account != finalAccount {
            onAccount(finalAccount)
            throw ClaudeCLIError.communication
        }
        guard let windows = ClaudeUsageParser.parse(output) else { throw ClaudeCLIError.usageUnrecognized }
        return windows
    }

    private func authStatus(executable: URL, directory: URL) throws -> ClaudeAuthStatus {
        let output = try capture(executable: executable, arguments: ["auth", "status", "--json"],
                                 directory: directory, usage: false, timeout: 10)
        guard let status = try? JSONDecoder().decode(ClaudeAuthStatus.self,
            from: Data(ClaudeUsageParser.clean(output).utf8)) else { throw ClaudeCLIError.communication }
        return status
    }

    // A native PTY keeps /usage in interactive-command mode without sending a model prompt.
    // Screen-reader mode makes panel updates line-oriented and avoids a terminal emulator.
    func capture(executable: URL, arguments: [String], directory: URL,
                 usage: Bool, timeout: TimeInterval) throws -> String {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 100, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw ClaudeCLIError.communication }
        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        defer {
            try? masterHandle.close()
            try? slaveHandle.close()
        }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        _ = fcntl(master, F_SETNOSIGPIPE, 1)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        var environment = CodexProcessEnvironment.make(baseEnvironment: ProcessInfo.processInfo.environment,
            executableURL: executable, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        environment["TERM"] = "xterm-256color"
        environment["NO_COLOR"] = "1"
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment.removeValue(forKey: "CLAUDECODE")
        process.environment = environment
        lock.lock()
        if isCancelled {
            lock.unlock()
            throw ClaudeCLIError.cancelled
        }
        do {
            try process.run()
            activeProcess = process
            lock.unlock()
        } catch {
            lock.unlock()
            throw ClaudeCLIError.communication
        }
        try? slaveHandle.close()
        let pid = process.processIdentifier
        let ownsGroup = getpgid(pid) == pid
        defer {
            Self.terminate(process, ownsGroup: ownsGroup)
            lock.lock()
            if activeProcess === process { activeProcess = nil }
            lock.unlock()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var lastRead = ProcessInfo.processInfo.systemUptime
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while ProcessInfo.processInfo.systemUptime < deadline {
            lock.lock()
            let cancelled = isCancelled
            lock.unlock()
            if cancelled { throw ClaudeCLIError.cancelled }
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 100)
            let count = Darwin.read(master, &bytes, bytes.count)
            if count > 0 {
                guard data.count + count <= Self.maximumCaptureBytes else { throw ClaudeCLIError.outputTooLarge }
                data.append(contentsOf: bytes.prefix(count))
                lastRead = ProcessInfo.processInfo.systemUptime
                if usage, let error = ClaudeUsageParser.blockingError(in: String(decoding: data, as: UTF8.self)) {
                    throw error
                }
            } else if count < 0 && errno != EAGAIN && errno != EINTR && errno != EIO {
                throw ClaudeCLIError.communication
            }
            // A child may close its terminal before exiting; avoid spinning on POLLHUP.
            if count <= 0, descriptor.revents & Int16(POLLHUP) != 0, process.isRunning { usleep(20_000) }
            let output = String(decoding: data, as: UTF8.self)
            if usage, ProcessInfo.processInfo.systemUptime - lastRead >= 0.8,
               ClaudeUsageParser.parse(output) != nil { return output }
            if !process.isRunning && count <= 0 {
                if usage, ClaudeUsageParser.parse(output) == nil { throw ClaudeCLIError.usageUnrecognized }
                return output
            }
        }
        throw ClaudeCLIError.timedOut
    }
}
