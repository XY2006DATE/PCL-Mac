import Foundation
import Network

/// Independent implementation of the public Scaffolding lobby code/framing used
/// by PCL CE, HMCL and FCL. References are in Support/Multiplayer/README.md.
public struct ScaffoldingInvite: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let code: String
    public let networkName: String
    public let networkSecret: String
    private static let alphabet = Array("0123456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    public var description: String { "Scaffolding room (credentials redacted)" }
    public var debugDescription: String { description }
    public init(_ text: String) throws {
        guard text.utf8.count <= 4096 else { throw PCLLinkError.invalid("大厅码过长。") }
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = value.range(of: "【"), let b = value.range(of: "】", range: a.upperBound..<value.endIndex) { value = String(value[a.upperBound..<b.lowerBound]) }
        value = value.uppercased().replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "I", with: "1")
        let parts = value.dropFirst(2).split(separator: "-", omittingEmptySubsequences: false)
        guard value.hasPrefix("U/"), value.count == 21, parts.count == 4, parts.allSatisfy({ $0.count == 4 }) else {
            throw PCLLinkError.invalid("大厅码格式无效，请复制完整的 U/ 大厅编号。")
        }
        var digits: [Int] = []
        for c in parts.joined() {
            guard let n = Self.alphabet.firstIndex(of: c) else { throw PCLLinkError.invalid("大厅码包含无效字符。") }
            digits.append(n)
        }
        guard digits.reversed().reduce(0, { ($0 * 34 + $1) % 7 }) == 0 else { throw PCLLinkError.invalid("大厅码校验失败，请重新复制。") }
        code = value
        let payload = String(value.dropFirst(2))
        networkName = "scaffolding-mc-" + payload.prefix(9)
        networkSecret = String(payload.suffix(9))
    }
    public static func create() -> Self {
        var rng = SystemRandomNumberGenerator()
        var digits = (0..<16).map { _ in Int.random(in: 0..<34, using: &rng) }
        let remainder = digits.reversed().reduce(0, { ($0 * 34 + $1) % 7 })
        digits[0] += digits[0] >= remainder ? -remainder : 7 - remainder
        let groups = stride(from: 0, to: 16, by: 4).map { start in String(digits[start..<(start + 4)].map { alphabet[$0] }) }
        return try! Self("U/" + groups.joined(separator: "-"))
    }
    public func redacting(_ text: String) -> String {
        text.replacingOccurrences(of: code, with: "[大厅码已隐藏]").replacingOccurrences(of: networkSecret, with: "[密钥已隐藏]")
            .replacingOccurrences(of: #"\u001B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
    }
}

struct ScaffoldingProfile: Codable, Sendable {
    let name: String
    let machine_id: String
    let vendor: String
    var kind: String?
}

enum ScaffoldingFrame {
    static func uint32(_ bytes: Data, _ offset: Int) -> Int {
        bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }
    static func size(_ value: Int) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    static func request(_ type: String, body: Data = Data()) -> Data {
        let name = Data(type.utf8)
        precondition(!name.isEmpty && name.count <= 128 && body.count <= 65536)
        return Data([UInt8(name.count)]) + name + size(body.count) + body
    }
    static func response(status: UInt8 = 0, body: Data = Data()) -> Data { Data([status]) + size(body.count) + body }
    static func takeRequest(_ buffer: inout Data) throws -> (String, Data)? {
        guard let n = buffer.first else { return nil }
        guard n > 0, n <= 128 else { throw PCLLinkError.invalid("大厅协议帧格式无效。") }
        let start = Int(n) + 5
        guard buffer.count >= start else { return nil }
        let count = uint32(buffer, Int(n) + 1)
        guard count <= 65536 else { throw PCLLinkError.invalid("大厅协议消息过大。") }
        guard buffer.count >= start + count else { return nil }
        guard let type = String(data: buffer.subdata(in: 1..<(1 + Int(n))), encoding: .ascii) else { throw PCLLinkError.invalid("大厅请求类型无效。") }
        let body = buffer.subdata(in: start..<(start + count))
        buffer = Data(buffer.dropFirst(start + count)); return (type, body)
    }
}

/// One bounded, cancellable RPC exchange. No credentials are placed in URLs.
enum ScaffoldingRPC {
    static func call(port: UInt16, type: String, body: Data = Data(), timeout: TimeInterval = 5) async throws -> Data {
        let exchange = Exchange()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { exchange.start(port, packet: ScaffoldingFrame.request(type, body: body), timeout: timeout, waiter: $0) }
        } onCancel: { exchange.cancel() }
    }
    private final class Exchange: @unchecked Sendable {
        let queue = DispatchQueue(label: "app.pcl.scaffolding.rpc")
        var waiter: CheckedContinuation<Data, Error>?
        var connection: NWConnection?
        var buffer = Data()
        var cancelled = false
        var timer: DispatchWorkItem?
        func start(_ port: UInt16, packet: Data, timeout: TimeInterval, waiter: CheckedContinuation<Data, Error>) {
            queue.async { [self] in
                self.waiter = waiter
                guard !cancelled, let endpoint = NWEndpoint.Port(rawValue: port), port > 0 else { finish(.failure(CancellationError())); return }
                let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp); self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                            if let error { self?.finish(.failure(error)) } else { self?.receive() }
                        })
                    case .failed(let error): self.finish(.failure(error))
                    case .cancelled: self.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(PCLLinkError.invalid("大厅协议请求超时。"))) }
                self.timer = timer; queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                connection.start(queue: queue)
            }
        }
        func receive() {
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 65541) { [weak self] data, _, complete, error in
                guard let self, self.waiter != nil else { return }
                if let data { self.buffer.append(data) }
                guard self.buffer.count <= 65541 else { self.finish(.failure(PCLLinkError.invalid("大厅响应过大。"))); return }
                if self.buffer.count >= 5 {
                    let size = ScaffoldingFrame.uint32(self.buffer, 1)
                    guard size <= 65536 else { self.finish(.failure(PCLLinkError.invalid("大厅响应过大。"))); return }
                    if self.buffer.count >= size + 5 {
                        guard self.buffer[0] == 0 else { self.finish(.failure(PCLLinkError.invalid("房主拒绝了大厅请求。"))); return }
                        self.finish(.success(self.buffer.subdata(in: 5..<(5 + size)))); return
                    }
                }
                if let error { self.finish(.failure(error)) }
                else if complete { self.finish(.failure(PCLLinkError.invalid("大厅连接已关闭。"))) }
                else { self.receive() }
            }
        }
        func cancel() { queue.async { [self] in cancelled = true; finish(.failure(CancellationError())) } }
        func finish(_ result: Result<Data, Error>) {
            guard let waiter else { return }; self.waiter = nil
            timer?.cancel(); timer = nil; connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
            waiter.resume(with: result)
        }
    }
}

/// Loopback control endpoint, reached remotely only through EasyTier's whitelist.
final class ScaffoldingServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.pcl.scaffolding.server")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var lastActivity: [UUID: TimeInterval] = [:]
    private var players: [String: (ScaffoldingProfile, Date)] = [:]
    private var cancelled = false
    private var startup: CheckedContinuation<Void, Error>?
    private var timeout: DispatchWorkItem?
    private let gamePort: UInt16
    private let host: ScaffoldingProfile
    init(gamePort: UInt16, host: ScaffoldingProfile) { self.gamePort = gamePort; self.host = host }
    func start(port: UInt16) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                queue.async { [self] in
                    startup = waiter
                    guard !cancelled else { finishStartup(.failure(CancellationError())); return }
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
                        let listener = try NWListener(using: parameters); self.listener = listener
                        listener.stateUpdateHandler = { [weak self] state in
                            if case .ready = state { self?.finishStartup(.success(())) }
                            if case .failed(let error) = state { self?.finishStartup(.failure(error)); self?.stop() }
                        }
                        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                        let timeout = DispatchWorkItem { [weak self] in self?.finishStartup(.failure(PCLLinkError.invalid("大厅控制端口启动超时。"))); self?.stop() }
                        self.timeout = timeout; queue.asyncAfter(deadline: .now() + 5, execute: timeout)
                        listener.start(queue: queue)
                    } catch { finishStartup(.failure(error)) }
                }
            }
        } onCancel: { self.stop() }
    }
    private func finishStartup(_ result: Result<Void, Error>) {
        guard let startup else { return }; self.startup = nil; timeout?.cancel(); timeout = nil; startup.resume(with: result)
    }
    private func accept(_ connection: NWConnection) {
        guard !cancelled, connections.count < 32 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection; lastActivity[id] = ProcessInfo.processInfo.systemUptime
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close(id) }
            if case .cancelled = state { self?.close(id) }
        }
        connection.start(queue: queue); receive(connection, id: id, buffer: Data())
        watchIdle(id)
    }
    private func watchIdle(_ id: UUID) {
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, let last = self.lastActivity[id] else { return }
            if ProcessInfo.processInfo.systemUptime - last >= 15 { self.close(id) } else { self.watchIdle(id) }
        }
    }
    private func close(_ id: UUID) {
        lastActivity.removeValue(forKey: id)
        let connection = connections.removeValue(forKey: id); connection?.stateUpdateHandler = nil; connection?.cancel()
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 131072 else { self.close(id); return }
            do {
                var responses = Data()
                while let (type, body) = try ScaffoldingFrame.takeRequest(&buffer) {
                    self.lastActivity[id] = ProcessInfo.processInfo.systemUptime
                    responses.append(self.respond(type, body: body))
                    guard responses.count <= 131072 else { self.close(id); return }
                }
                let remaining = buffer
                if !responses.isEmpty {
                    connection.send(content: responses, completion: .contentProcessed { [weak self] sendError in
                        guard let self else { return }
                        if sendError != nil || error != nil || complete { self.close(id) }
                        else { self.receive(connection, id: id, buffer: remaining) }
                    })
                } else if error != nil || complete { self.close(id) }
                else { self.receive(connection, id: id, buffer: remaining) }
            } catch { self.close(id) }
        }
    }
    private func respond(_ type: String, body: Data) -> Data {
        switch type {
        case "c:server_port": return ScaffoldingFrame.response(body: Data([UInt8(gamePort >> 8), UInt8(gamePort & 255)]))
        case "c:protocols": return ScaffoldingFrame.response(body: Data("c:ping\0c:protocols\0c:server_port\0c:player_ping\0c:player_profiles_list".utf8))
        case "c:ping": return ScaffoldingFrame.response(body: body)
        case "c:player_ping":
            guard var profile = try? JSONDecoder().decode(ScaffoldingProfile.self, from: body), !profile.machine_id.isEmpty,
                  profile.machine_id.count <= 128, profile.name.count <= 64, profile.vendor.count <= 128,
                  players.count < 64 || players[profile.machine_id] != nil else { return ScaffoldingFrame.response(status: 32) }
            profile.kind = "GUEST"; players[profile.machine_id] = (profile, Date()); return ScaffoldingFrame.response()
        case "c:player_profiles_list":
            players = players.filter { Date().timeIntervalSince($0.value.1) < 10 }
            let profiles = [host] + players.values.map(\.0)
            guard let bytes = try? JSONEncoder().encode(profiles), bytes.count <= 65536 else { return ScaffoldingFrame.response(status: 32) }
            return ScaffoldingFrame.response(body: bytes)
        default: return ScaffoldingFrame.response(status: 1)
        }
    }
    func stop() { queue.async { [self] in
        cancelled = true; finishStartup(.failure(CancellationError())); listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil; listener?.cancel(); listener = nil
        for id in Array(connections.keys) { close(id) }; players.removeAll()
    } }
}
