import Foundation
import Network
import Darwin

/// Reserves TCP and UDP ports together until the child is ready to bind them.
final class LinkPortReservations {
    private var descriptors: [Int32] = []
    private var selected = Set<UInt16>()
    init(excluding: Set<UInt16>) { selected = excluding }
    func reserve() throws -> UInt16 {
        for _ in 0..<32 {
            let tcp = socket(AF_INET, SOCK_STREAM, 0)
            guard tcp >= 0 else { throw PCLLinkError.invalid("无法创建联机端口。") }
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(tcp, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            var count = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(tcp, $0, &count) } }
            let port = UInt16(bigEndian: address.sin_port)
            guard bound == 0, named == 0, port > 1024, !selected.contains(port) else { Darwin.close(tcp); continue }
            let udp = socket(AF_INET, SOCK_DGRAM, 0)
            let udpBound = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(udp, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard udp >= 0, udpBound == 0 else { Darwin.close(tcp); if udp >= 0 { Darwin.close(udp) }; continue }
            descriptors += [tcp, udp]; selected.insert(port); return port
        }
        throw PCLLinkError.invalid("无法分配不冲突的联机端口，请关闭占用端口的程序后重试。")
    }
    func release() { descriptors.forEach { Darwin.close($0) }; descriptors = [] }
    deinit { release() }
}

public enum LinkTCPProbe {
    public static func connect(port: UInt16, timeout: TimeInterval = 2) async throws {
        let state = Probe()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in state.start(port: port, timeout: timeout, continuation: continuation) }
        } onCancel: { state.cancel() }
    }
    private final class Probe: @unchecked Sendable {
        private let queue = DispatchQueue(label: "app.pcl.link.probe")
        private var continuation: CheckedContinuation<Void, Error>?
        private var connection: NWConnection?
        private var cancelled = false
        private var timer: DispatchWorkItem?
        func start(port: UInt16, timeout: TimeInterval, continuation: CheckedContinuation<Void, Error>) {
            queue.async { [self] in
                self.continuation = continuation
                guard !cancelled else { finish(.failure(CancellationError())); return }
                guard let endpoint = NWEndpoint.Port(rawValue: port), port > 0 else {
                    finish(.failure(PCLLinkError.invalid("无效的本机端口。"))); return
                }
                let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.finish(.success(()))
                    case .failed: self.finish(.failure(PCLLinkError.invalid("本机游戏或转发端口尚未就绪。")))
                    case .cancelled: self.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(PCLLinkError.invalid("本机端口连接超时。"))) }
                self.timer = timer
                queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                connection.start(queue: queue)
            }
        }
        func cancel() { queue.async { [self] in cancelled = true; finish(.failure(CancellationError())) } }
        private func finish(_ result: Result<Void, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timer?.cancel(); timer = nil
            connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
            continuation.resume(with: result)
        }
    }
}

/// Original PCL's loopback announcement lets Minecraft discover the local forward.
final class LinkLANAdvertisement: @unchecked Sendable {
    private var timer: DispatchSourceTimer?
    private var descriptor: Int32 = -1
    init(port: UInt16) throws {
        descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw PCLLinkError.invalid("无法创建局域网房间广播。") }
        let fd = descriptor
        var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET); target.sin_addr.s_addr = inet_addr("127.0.0.1"); target.sin_port = UInt16(4445).bigEndian
        let packet = Data("[MOTD]PCL 联机房间[/MOTD][AD]\(port)[/AD]".utf8)
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.setEventHandler {
            packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: target) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                } }
            }
        }
        source.schedule(deadline: .now(), repeating: 1.5)
        source.setCancelHandler { Darwin.close(fd) }; timer = source; source.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
    deinit { stop() }
}
