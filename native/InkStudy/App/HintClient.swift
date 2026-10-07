import Foundation
import InkStudyCore

struct RemoteHint: Codable, Sendable {
    let requestID: UUID
    let strategy: HintStrategy
    let model: String
    let latencyMilliseconds: Int
    let version: String
}

@MainActor
protocol HintSelecting: AnyObject {
    func select(evidence: HintEvidence, level: Int, requestID: UUID) async throws -> RemoteHint
}

struct HintClientError: Error, LocalizedError {
    let code: String
    var errorDescription: String? { "提示服务未连接或暂不可用（\(code)），仍可使用本地提示。" }
}

@MainActor
final class HintClient: ObservableObject, HintSelecting {
    @Published var endpoint: String { didSet { preferences.set(endpoint, forKey: "Hints.endpoint") } }
    @Published var adultRehearsalConsent: Bool { didSet { preferences.set(adultRehearsalConsent, forKey: "Hints.adultConsent") } }
    @Published private(set) var status = "未连接；C 组将使用本地动作提示"
    @Published private(set) var busy = false
    private let preferences: UserDefaults
    private let session: URLSession
    private var deviceID: UUID {
        if let id = preferences.string(forKey: "Hints.deviceID").flatMap(UUID.init(uuidString:)) { return id }
        let id = UUID(); preferences.set(id.uuidString, forKey: "Hints.deviceID"); return id
    }
    init(preferences: UserDefaults = .standard, session: URLSession? = nil) {
        self.preferences = preferences; endpoint = preferences.string(forKey: "Hints.endpoint") ?? ""
        adultRehearsalConsent = preferences.bool(forKey: "Hints.adultConsent")
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 12
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration, delegate: HintNoRedirects(), delegateQueue: nil)
        }
    }
    func pair(code: String) async {
        guard !busy else { return }; busy = true
        defer { busy = false }
        do {
            let address = try BridgeAddress.normalize(endpoint)
            let body = try JSONSerialization.data(withJSONObject: ["code": code, "deviceID": deviceID.uuidString, "label": "Hint preview iPad"])
            let data = try await send(address: address, route: "/v1/pair", body: body, authenticated: false)
            struct Pair: Decodable { let token: String; let deviceID: UUID }
            let pair = try JSONDecoder().decode(Pair.self, from: data)
            guard pair.deviceID == deviceID, pair.token.count >= 40 else { throw HintClientError(code: "invalid_pairing") }
            try BridgeKeychain.save(pair.token, endpoint: "hints:" + address.absoluteString)
            endpoint = address.absoluteString; await check()
        } catch { status = "配对失败，请检查地址和一次性配对码。" }
    }
    func check() async {
        do {
            let data = try await send(address: BridgeAddress.normalize(endpoint), route: "/v1/status")
            struct Status: Decodable { let configured: Bool; let model: String; let version: String }
            let result = try JSONDecoder().decode(Status.self, from: data)
            guard result.configured, result.version == MultimodalFeedback.version else { throw HintClientError(code: "version_mismatch") }
            status = "已连接 DeepSeek · " + result.model
        } catch { status = "未连接；检查 Mac 服务、网络和配对设置" }
    }
    func select(evidence: HintEvidence, level: Int, requestID: UUID) async throws -> RemoteHint {
        guard adultRehearsalConsent else { throw HintClientError(code: "adult_rehearsal_consent_required") }
        struct Request: Encodable {
            let version = MultimodalFeedback.version
            let requestID: UUID
            let mode = "adult_rehearsal"
            let uploadConsent = true
            let group = "C"
            let level: Int
            let summary: HintSummary
        }
        let body = try JSONEncoder().encode(Request(requestID: requestID, level: level, summary: evidence.summary))
        let data = try await send(address: BridgeAddress.normalize(endpoint), route: "/v1/hints", body: body)
        let result = try JSONDecoder().decode(RemoteHint.self, from: data)
        guard result.requestID == requestID, result.version == MultimodalFeedback.version,
              MultimodalFeedback.candidates(evidence).contains(result.strategy), result.model.hasPrefix("deepseek-"),
              result.model.count <= 80, (0...120_000).contains(result.latencyMilliseconds) else { throw HintClientError(code: "invalid_response") }
        return result
    }
    private func send(address: URL, route: String, body: Data? = nil, authenticated: Bool = true) async throws -> Data {
        guard let url = URL(string: address.absoluteString + route) else { throw HintClientError(code: "invalid_address") }
        var request = URLRequest(url: url); request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let token = try BridgeKeychain.token(for: "hints:" + address.absoluteString) else { throw HintClientError(code: "pairing_required") }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 8192 else { throw HintClientError(code: "invalid_response") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8192 else { throw HintClientError(code: "response_too_large") }; data.append(byte)
        }
        guard (200..<300).contains(response.statusCode) else { throw HintClientError(code: "http_\(response.statusCode)") }
        return data
    }
}

private final class HintNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
