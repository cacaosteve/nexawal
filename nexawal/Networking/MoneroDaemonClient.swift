//
//  MoneroDaemonClient.swift
//  nexawal
//
//  Minimal Monero daemon JSON-RPC client (get_info)
//
//

import Foundation
import CFNetwork

enum MoneroDaemonClientError: LocalizedError {
    case invalidBaseURL(String)
    case invalidProxyAddress(String)
    case transport(Error)
    case nonHTTPResponse
    case httpStatus(Int, body: String)
    case decodingFailed(String)
    case rpcError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let s):
            return "Invalid daemon URL: \(s)"
        case .invalidProxyAddress(let s):
            return "Invalid proxy address: \(s)"
        case .transport(let e):
            return "Network error: \(e.localizedDescription)"
        case .nonHTTPResponse:
            return "Unexpected response type from daemon"
        case .httpStatus(let code, let body):
            return "Daemon HTTP error \(code): \(body)"
        case .decodingFailed(let msg):
            return "Failed to decode daemon response: \(msg)"
        case .rpcError(let code, let message):
            return "Daemon RPC error \(code): \(message)"
        }
    }
}

struct MoneroDaemonInfo: Sendable, Equatable {
    /// Daemon-reported current height (may lag if daemon is syncing).
    let height: UInt64
    /// Daemon-reported target height (best-known chain tip target).
    let targetHeight: UInt64
}

enum MoneroDaemonClient {
    // MARK: - Public API

    /// Calls the daemon JSON-RPC `get_info` method.
    /// - Parameter baseURL: e.g. "http://127.0.0.1:18089"
    /// - Parameter proxyAddress: Optional HTTP proxy "host:port" (useful for I2P).
    /// - Returns: Parsed heights (height + target_height).
    static func getInfo(
        baseURL: String,
        proxyAddress: String? = nil,
        timeout: TimeInterval = 8.0
    ) async throws -> MoneroDaemonInfo {
        let url = try jsonRPCURL(from: baseURL)

        let request = JSONRPCRequest(method: "get_info", params: nil)
        let body = try JSONEncoder().encode(request)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = timeout

        let session: URLSession = try makeSession(proxyAddress: proxyAddress, timeout: timeout)

        #if DEBUG
        let proxyDesc = proxyAddress ?? "(none)"
        print("🛰️ get_info: url=\(url.absoluteString), proxy=\(proxyDesc)")
        #endif

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw MoneroDaemonClientError.nonHTTPResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                throw MoneroDaemonClientError.httpStatus(http.statusCode, body: bodyStr)
            }

            let decoded: JSONRPCResponse<GetInfoResult>
            do {
                decoded = try JSONDecoder().decode(JSONRPCResponse<GetInfoResult>.self, from: data)
            } catch {
                let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                throw MoneroDaemonClientError.decodingFailed("\(error.localizedDescription). Body=\(bodyStr)")
            }

            if let rpcErr = decoded.error {
                throw MoneroDaemonClientError.rpcError(code: rpcErr.code, message: rpcErr.message)
            }
            guard let result = decoded.result else {
                throw MoneroDaemonClientError.decodingFailed("Missing result in JSON-RPC response")
            }

            #if DEBUG
            print("🛰️ get_info: height=\(result.height) target_height=\(result.target_height)")
            #endif

            return MoneroDaemonInfo(height: result.height, targetHeight: result.target_height)
        } catch let e as MoneroDaemonClientError {
            #if DEBUG
            print("🛰️ get_info failed: \(e.localizedDescription)")
            #endif
            throw e
        } catch {
            #if DEBUG
            print("🛰️ get_info transport failed: \(error.localizedDescription)")
            #endif
            throw MoneroDaemonClientError.transport(error)
        }
    }

    // MARK: - Helpers

    private static func makeSession(proxyAddress: String?, timeout: TimeInterval) throws -> URLSession {
        guard let proxyAddress, !proxyAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .shared
        }

        let (host, port) = try parseHostPort(proxyAddress)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout

        // iOS does not expose the CFNetwork HTTPS proxy constants (they're marked unavailable).
        // Using the HTTP proxy keys here is sufficient for typical I2P HTTP proxy setups (e.g. i2p SAM/HTTP proxy),
        // and avoids build failures on iOS.
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port
        ]

        return URLSession(configuration: cfg)
    }

    private static func parseHostPort(_ s: String) throws -> (host: String, port: Int) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Expect "host:port" (IPv6 not supported here; keep it simple for NexaWal’s current defaults)
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { throw MoneroDaemonClientError.invalidProxyAddress(s) }

        let host = String(parts[0])
        guard !host.isEmpty else { throw MoneroDaemonClientError.invalidProxyAddress(s) }

        guard let port = Int(parts[1]), port > 0, port < 65536 else {
            throw MoneroDaemonClientError.invalidProxyAddress(s)
        }

        return (host: host, port: port)
    }

    private static func jsonRPCURL(from baseURL: String) throws -> URL {
        // Allow callers to pass either a daemon base URL or a full /json_rpc endpoint.
        // Normalize to /json_rpc.
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MoneroDaemonClientError.invalidBaseURL(baseURL) }

        guard var url = URL(string: trimmed) else {
            throw MoneroDaemonClientError.invalidBaseURL(baseURL)
        }

        // If base URL is like http://host:18089 (no /json_rpc), append it.
        if url.path.isEmpty || url.path == "/" {
            url.appendPathComponent("json_rpc")
        } else if !url.path.hasSuffix("/json_rpc") {
            // If some other path is provided, do not override; but common configs use /json_rpc.
            // We only append when it looks like a plain host.
        }

        return url
    }
}

// MARK: - JSON-RPC types

private struct JSONRPCRequest: Encodable {
    let jsonrpc: String = "2.0"
    let id: String = "0"
    let method: String
    let params: [String: String]?

    init(method: String, params: [String: String]?) {
        self.method = method
        self.params = params
    }
}

private struct JSONRPCResponse<Result: Decodable>: Decodable {
    struct RPCError: Decodable {
        let code: Int
        let message: String
    }

    let jsonrpc: String?
    let id: String?
    let result: Result?
    let error: RPCError?
}

/// Minimal subset of fields from daemon `get_info`.
private struct GetInfoResult: Decodable {
    let height: UInt64
    let target_height: UInt64
}
