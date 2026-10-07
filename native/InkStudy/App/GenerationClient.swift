import Foundation
import Security
import UIKit
import InkStudyCore

enum BridgeAddress {
    static func normalize(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", ["https", "http"].contains(url.scheme) else {
            throw DrawingError.invalidEvent("请输入服务端地址，不包含账号、密码、路径或查询参数。")
        }
        if url.scheme != "https" {
            #if DEBUG || HINTS_PREVIEW
            let parts = host.split(separator: ".").compactMap { Int($0) }
            let privateIPv4 = parts.count == 4 && parts.allSatisfy({ (0...255).contains($0) }) &&
                (parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])))
            guard host == "localhost" || host.hasSuffix(".local") || privateIPv4 else {
                throw DrawingError.invalidEvent("HTTP 只允许本机或私有局域网测试地址。部署时请使用 HTTPS。")
            }
            #else
            throw DrawingError.invalidEvent("此版本只连接使用可信证书的 HTTPS 服务端。")
            #endif
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw DrawingError.invalidEvent("服务地址无效。") }
        components.path = ""; components.host = host.lowercased()
        return try components.url.unwrap("服务地址无效。")
    }
}

enum BridgeKeychain {
    static func token(for endpoint: String) throws -> String? {
        var query = base(endpoint); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw DrawingError.persistence("无法读取设备配对凭证（\(status)）。") }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String, endpoint: String) throws {
        let query = base(endpoint)
        let updates: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw DrawingError.persistence("无法更新配对凭证（\(status)）。") }
        var item = query; item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw DrawingError.persistence("无法保存配对凭证（\(added)）。") }
    }
    private static func base(_ endpoint: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "cn.xinsun.inkstudy.bridge", kSecAttrAccount as String: endpoint]
    }
}

struct BridgeFailure: Codable, Equatable, Sendable, Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}
struct RemoteGeneration: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let status: String
    let createdAt: String
    let updatedAt: String
    let providerTaskID: String?
    let providerRequestID: String?
    let resultFile: String?
    let resultSHA256: String?
    let resultMimeType: String?
    let error: BridgeFailure?
}
struct GenerationRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let endpoint: String
    let sourceDocumentID: UUID
    let sourcePNGHash: String
    let prompt: String
    let seed: Int
    let mode: String
    let participantCode: String?
    let createdAt: Date
    let consentAt: Date
    let model: String
    let function: String
    let isSketch: Bool
    let watermark: Bool
    let imageCount: Int
    let appVersion: String?
    var receipts: [RemoteGeneration]
    var localError: String?
    var downloadedFile: String?
    var remote: RemoteGeneration? { receipts.last }
    var needsUpdate: Bool { remote?.status != "FAILED" && remote?.status != "SUBMISSION_UNKNOWN" && (remote?.status != "SUCCEEDED" || downloadedFile == nil) }
    var statusLabel: String {
        if let localError { return localError }
        switch remote?.status {
        case "QUEUED": return "已接收，等待生成"
        case "SUBMITTING": return "正在提交万相任务"
        case "PENDING", "RUNNING": return "万相正在生成，可以离开此页稍后查看"
        case "RESULT_PENDING": return "云端已生成，正在取回图片"
        case "SUCCEEDED": return downloadedFile == nil ? "等待下载生成图" : "生成图已保存到本机"
        case "FAILED": return remote?.error?.message ?? "云端生成未完成"
        case "SUBMISSION_UNKNOWN": return "提交结果未知，请先核对云端任务，不要重复生成"
        default: return "原画已保存，等待提交或恢复连接"
        }
    }
}

@MainActor
final class GenerationClient {
    private struct FailureResponse: Decodable { let error: BridgeFailure }
    private struct PairResponse: Decodable { let token: String; let deviceID: String }
    private struct PairRequest: Encodable { let code: String; let deviceID: String; let label: String }
    private struct SubmitRequest: Encodable {
        let imageBase64: String; let sourceDocumentID: UUID; let prompt: String; let seed: Int
        let mode: String; let participantCode: String?; let uploadConsent = true; let appVersion: String
    }
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 35; configuration.timeoutIntervalForResource = 90
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration, delegate: NoBridgeRedirects(), delegateQueue: nil)
        }
    }
    func pair(endpoint: URL, code: String, deviceID: UUID) async throws {
        let body = try JSONEncoder().encode(PairRequest(code: code, deviceID: deviceID.uuidString, label: UIDevice.current.model))
        let data = try await send(endpoint: endpoint, route: "/v1/pair", method: "POST", body: body, authenticated: false)
        let result = try JSONDecoder().decode(PairResponse.self, from: data)
        guard result.deviceID == deviceID.uuidString, result.token.count >= 40 else { throw DrawingError.invalidEvent("服务端配对响应无效。") }
        try BridgeKeychain.save(result.token, endpoint: endpoint.absoluteString)
    }
    func status(endpoint: URL) async throws -> Bool {
        let data = try await send(endpoint: endpoint, route: "/v1/status")
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["configured"] as? Bool == true
    }
    func fetch(_ record: GenerationRecord) async throws -> RemoteGeneration {
        let endpoint = try BridgeAddress.normalize(record.endpoint)
        let data = try await send(endpoint: endpoint, route: "/v1/generations/" + record.id.uuidString)
        return try JSONDecoder().decode(RemoteGeneration.self, from: data)
    }
    func submit(_ record: GenerationRecord, png: Data) async throws -> RemoteGeneration {
        guard RawDrawingExport.sha256(png) == record.sourcePNGHash else { throw DrawingError.persistence("原画快照校验失败，未上传。") }
        let body = try JSONEncoder().encode(SubmitRequest(imageBase64: png.base64EncodedString(), sourceDocumentID: record.sourceDocumentID,
            prompt: record.prompt, seed: record.seed, mode: record.mode, participantCode: record.participantCode,
            appVersion: record.appVersion ?? "0.3.0"))
        let data = try await send(endpoint: BridgeAddress.normalize(record.endpoint), route: "/v1/generations/" + record.id.uuidString, method: "PUT", body: body)
        return try JSONDecoder().decode(RemoteGeneration.self, from: data)
    }
    func image(_ record: GenerationRecord) async throws -> Data {
        try await send(endpoint: BridgeAddress.normalize(record.endpoint), route: "/v1/generations/" + record.id.uuidString + "/image", limit: 32 * 1024 * 1024)
    }
    private func send(endpoint: URL, route: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true, limit: Int = 1024 * 1024) async throws -> Data {
        let url = try URL(string: endpoint.absoluteString + route).unwrap("请求地址无效。")
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let token = try BridgeKeychain.token(for: endpoint.absoluteString) else { throw BridgeFailure(code: "authentication_required", message: "请先打开连接设置，与服务端配对。") }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= Int64(limit) else { throw DrawingError.invalidEvent("服务响应无效或超过大小限制。") }
        var data = Data()
        for try await byte in stream {
            if data.count >= limit { throw DrawingError.invalidEvent("服务响应超过大小限制。") }
            data.append(byte)
        }
        guard (200..<300).contains(response.statusCode) else {
            if let failure = try? JSONDecoder().decode(FailureResponse.self, from: data) { throw failure.error }
            throw BridgeFailure(code: "http_\(response.statusCode)", message: "连接未完成（\(response.statusCode)），原画已保留。")
        }
        return data
    }
}

private final class NoBridgeRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw DrawingError.invalidEvent(message) }; return value
    }
}
