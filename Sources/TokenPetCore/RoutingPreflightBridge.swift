import Darwin
import Foundation

public struct PendingRoutingReplay: Codable, Equatable, Sendable {
    public var sessionID: String
    public var prompt: String
    public var current: RoutingSelection
    public var recommended: RoutingSelection
    public var reasonCode: String
    public var upgradeCondition: String?
    public var observedAt: Date

    public init(
        sessionID: String,
        prompt: String,
        current: RoutingSelection,
        recommended: RoutingSelection,
        reasonCode: String,
        upgradeCondition: String?,
        observedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.prompt = prompt
        self.current = current
        self.recommended = recommended
        self.reasonCode = reasonCode
        self.upgradeCondition = upgradeCondition
        self.observedAt = observedAt
    }
}

public final class RoutingPreflightBridgeServer: @unchecked Sendable {
    public typealias Handler = @Sendable (PendingRoutingReplay) -> Void

    private let socketPath: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.codex-session-guardian.routing-preflight-bridge")
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    public init(
        socketPath: String = RoutingPreflightBridgeServer.defaultSocketPath,
        handler: @escaping Handler
    ) {
        self.socketPath = socketPath
        self.handler = handler
    }

    deinit { stop() }

    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenPet/preflight.sock").path
    }

    public func start() throws {
        guard descriptor < 0 else { return }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw bridgeError("socket") }
        do {
            var address = try unixAddress(path: socketPath)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw bridgeError("bind") }
            guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else { throw bridgeError("chmod") }
            guard listen(fd, 8) == 0 else { throw bridgeError("listen") }
        } catch {
            Darwin.close(fd)
            unlink(socketPath)
            throw error
        }
        descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAvailableConnections() }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
        unlink(socketPath)
    }

    private func acceptAvailableConnections() {
        guard descriptor >= 0 else { return }
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while data.count <= 256 * 1_024 {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        guard data.count <= 256 * 1_024,
              let replay = try? JSONDecoder().decode(PendingRoutingReplay.self, from: data),
              replay.prompt.utf8.count <= 64 * 1_024,
              Date().timeIntervalSince(replay.observedAt) < 30
        else { return }
        handler(replay)
    }
}

public enum RoutingPreflightBridgeClient {
    @discardableResult
    public static func send(
        _ replay: PendingRoutingReplay,
        socketPath: String = RoutingPreflightBridgeServer.defaultSocketPath
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(replay), data.count <= 256 * 1_024 else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard var address = try? unixAddress(path: socketPath) else { return false }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}

private func unixAddress(path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8CString)
    var address = sockaddr_un()
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw NSError(
            domain: "RoutingPreflightBridge",
            code: Int(ENAMETOOLONG),
            userInfo: [NSLocalizedDescriptionKey: "Routing bridge socket path is too long"])
    }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
            for (index, byte) in bytes.enumerated() { destination[index] = byte }
        }
    }
    return address
}

private func bridgeError(_ operation: String) -> NSError {
    NSError(
        domain: "RoutingPreflightBridge",
        code: Int(errno),
        userInfo: [NSLocalizedDescriptionKey: "Routing bridge \(operation) failed: \(String(cString: strerror(errno)))"])
}
