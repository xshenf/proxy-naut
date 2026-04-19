import Foundation
import Network

enum ProxyProtocol: String, Codable, CaseIterable {
    case http
    case https
    case socks5
    case shadowsocks
    case vmess
    case trojan
    case vless
    case hysteria2
    case tuic

    var displayName: String {
        switch self {
        case .http: return "HTTP"
        case .https: return "HTTPS"
        case .socks5: return "SOCKS5"
        case .shadowsocks: return "Shadowsocks"
        case .vmess: return "VMess"
        case .trojan: return "Trojan"
        case .vless: return "VLESS"
        case .hysteria2: return "Hysteria2"
        case .tuic: return "TUIC"
        }
    }
}

enum OutboundAction {
    case proxy
    case direct
    case reject
}

struct TargetInfo {
    let host: String
    let port: UInt16
    
    var addressString: String {
        "\(host):\(port)"
    }
}

enum ProxyError: Error, LocalizedError {
    case invalidConfiguration
    case connectionFailed(String)
    case authenticationFailed
    case protocolError(String)
    case notRunning
    case portInUse
    case unsupportedProtocol
    
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Invalid proxy configuration"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .authenticationFailed:
            return "Authentication failed"
        case .protocolError(let reason):
            return "Protocol error: \(reason)"
        case .notRunning:
            return "Proxy is not running"
        case .portInUse:
            return "Port is already in use"
        case .unsupportedProtocol:
            return "Unsupported protocol"
        }
    }
}

protocol ProxyHandler: AnyObject {
    func start(listeningOn port: UInt16) throws
    func stop()
    /// 异步停止，等待 listener 完全释放端口
    func stopAsync() async
    func handleConnection(_ connection: NWConnection) -> AsyncThrowingStream<Data, Error>
    
    /// 创建出站代理连接（包含协议握手）
    /// - Parameters:
    ///   - target: 最终目标地址
    ///   - completion: 建立并完成协议握手后的远程连接
    func createProxyConnection(to target: TargetInfo, completion: @escaping (NWConnection?) -> Void)
    
    /// 直接转发连接（由 Handler 接手从首个字节开始的完整隧道逻辑）
    /// 适用于 gRPC 等无法返回原始 NWConnection 的传输协议
    func forwardConnection(local: NWConnection, to target: TargetInfo, initialData: Data?)
    
    var isRunning: Bool { get }
    var supportedProtocols: [ProxyProtocol] { get }
}

extension ProxyHandler {
    /// 默认实现：调用同步 stop()，然后等待端口释放
    func stopAsync() async {
        stop()
        // 等待操作系统释放端口
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
    }
    
    /// 默认实现：回退到传统的 createProxyConnection + 管道逻辑
    func forwardConnection(local: NWConnection, to target: TargetInfo, initialData: Data? = nil) {
        createProxyConnection(to: target) { remote in
            guard let remote = remote else {
                local.cancel()
                return
            }
            
            if let data = initialData {
                remote.send(content: data, completion: .contentProcessed { _ in
                    self.startLegacyTunnel(local: local, remote: remote)
                })
            } else {
                self.startLegacyTunnel(local: local, remote: remote)
            }
        }
    }
    
    private func startLegacyTunnel(local: NWConnection, remote: NWConnection) {
        // 简单的 TCP 管道实现
        func tunnel(from: NWConnection, to: NWConnection) {
            from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data = data {
                    to.send(content: data, completion: .contentProcessed { _ in
                        if !isComplete && error == nil {
                            tunnel(from: from, to: to)
                        }
                    })
                }
                if isComplete || error != nil {
                    from.cancel()
                    to.cancel()
                }
            }
        }
        
        tunnel(from: local, to: remote)
        tunnel(from: remote, to: local)
    }
}

struct ProxyStatistics: Codable {
    var bytesSent: UInt64 = 0
    var bytesReceived: UInt64 = 0
    var connectionCount: Int = 0
    var activeConnections: Int = 0
    var startDate: Date?
    
    // 实时网速
    var currentUploadSpeed: Double = 0
    var currentDownloadSpeed: Double = 0
    
    // 平均网速（由启动时间计算）
    var averageUploadSpeed: Double {
        guard let startDate = startDate, -startDate.timeIntervalSinceNow > 0 else { return 0 }
        return Double(bytesSent) / (-startDate.timeIntervalSinceNow)
    }
    
    var averageDownloadSpeed: Double {
        guard let startDate = startDate, -startDate.timeIntervalSinceNow > 0 else { return 0 }
        return Double(bytesReceived) / (-startDate.timeIntervalSinceNow)
    }
}