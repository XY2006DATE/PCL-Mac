import Foundation
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
    public enum Failure: LocalizedError, Equatable {
        case notListening(UInt16), timedOut(UInt16), restricted(UInt16), unavailable(UInt16)
        public var errorDescription: String? {
            switch self {
            case .notListening(let port): return "本机端口 \(port) 拒绝连接，尚无可连接的服务。"
            case .timedOut(let port): return "连接本机端口 \(port) 超时。"
            case .restricted(let port): return "系统限制了对本机端口 \(port) 的访问，请检查启动器的本地网络权限或网络过滤规则。"
            case .unavailable(let port): return "无法连接本机端口 \(port)。"
            }
        }
    }
    /// Hosting requires the player's already-open LAN world, not a relay server.
    public static func requireGame(port: UInt16, timeout: TimeInterval = 3) async throws {
        do { try await connect(port: port, timeout: timeout) }
        catch let error as Failure {
            if case .restricted = error { throw error }
            throw PCLLinkError.invalid("未能连接本机 Minecraft 游戏端口 \(port)。请先启动游戏并进入单人世界，点击“对局域网开放”，填写本次提示的端口，并保持世界运行。")
        }
    }
    /// EasyTier may acknowledge a forward before its listener has bound.
    public static func waitForForward(port: UInt16, timeout: TimeInterval = 8) async throws {
        guard port > 0, timeout.isFinite, timeout > 0 else { throw PCLLinkError.invalid("无效的转发端口或等待时间。") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            do {
                try await connect(port: port, timeout: min(1, max(0.01, deadline - ProcessInfo.processInfo.systemUptime)))
                return
            } catch is CancellationError { throw CancellationError() }
            catch let error as Failure { if case .restricted = error { throw error } }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(min(0.15, remaining) * 1_000_000_000)) }
        }
        throw PCLLinkError.invalid("等待本机联机转发端口 \(port) 就绪超时。请重新加入房间，并查看联机日志。")
    }
    public static func connect(port: UInt16, timeout: TimeInterval = 2) async throws {
        guard port > 0, timeout.isFinite, timeout > 0 else { throw PCLLinkError.invalid("无效的本机端口或等待时间。") }
        let state = Probe()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in state.start(port: port, timeout: timeout, continuation: continuation) }
        } onCancel: { state.cancel() }
    }
    private final class Probe: @unchecked Sendable {
        private let queue = DispatchQueue(label: "app.pcl.link.probe")
        private var continuation: CheckedContinuation<Void, Error>?
        private var descriptor: Int32 = -1
        private var writable: DispatchSourceWrite?
        private var cancelled = false
        private var timer: DispatchWorkItem?
        func start(port: UInt16, timeout: TimeInterval, continuation: CheckedContinuation<Void, Error>) {
            queue.async { [self] in
                self.continuation = continuation
                guard !cancelled else { finish(.failure(CancellationError())); return }
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { finish(.failure(Self.failure(errno, port: port))); return }
                descriptor = fd
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    finish(.failure(Self.failure(errno, port: port))); return
                }
                var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                let status = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if status == 0 { finish(.success(())); return }
                let code = errno
                guard code == EINPROGRESS || code == EWOULDBLOCK else { finish(.failure(Self.failure(code, port: port))); return }
                // Read the actual connect result instead of allowing Network.framework
                // to silently retry a refused loopback endpoint until our timer expires.
                let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                writable = source
                source.setEventHandler { [weak self] in
                    guard let self, self.continuation != nil, self.descriptor == fd else { return }
                    var error: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
                    if getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) != 0 { error = errno }
                    self.finish(error == 0 ? .success(()) : .failure(Self.failure(error, port: port)))
                }
                source.setCancelHandler { Darwin.close(fd) }; source.resume()
                let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(Failure.timedOut(port))) }
                self.timer = timer; queue.asyncAfter(deadline: .now() + timeout, execute: timer)
            }
        }
        private static func failure(_ code: Int32, port: UInt16) -> Failure {
            switch code {
            case ECONNREFUSED: return .notListening(port)
            case EACCES, EPERM: return .restricted(port)
            case ETIMEDOUT: return .timedOut(port)
            default: return .unavailable(port)
            }
        }
        func cancel() { queue.async { [self] in cancelled = true; finish(.failure(CancellationError())) } }
        private func finish(_ result: Result<Void, Error>) {
            guard let continuation else { return }
            self.continuation = nil; timer?.cancel(); timer = nil
            if let source = writable {
                source.setEventHandler {}; source.cancel(); writable = nil
            } else if descriptor >= 0 { Darwin.close(descriptor) }
            descriptor = -1
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
