import XCTest
import UIKit
import InkStudyCore
@testable import InkStudy

private final class BridgeProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@MainActor
final class GenerationAppTests: XCTestCase {
    private func environment() -> (GenerationModel, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GenerationAppTests-" + UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BridgeProtocolStub.self]
        let model = GenerationModel(directory: directory, client: GenerationClient(session: URLSession(configuration: config)))
        model.load()
        return (model, "https://localhost:" + String(Int.random(in: 20000...60000)))
    }
    private func document() throws -> StoredDocument {
        let metadata = DocumentMetadata(title: "Adult synthetic generation test"), id = UUID()
        let samples = (0..<30).map { TouchSample(uptime: Double($0) / 100, x: 200 + Double($0) * 20, y: 425, force: 1, maximumPossibleForce: 4) }
        return .init(metadata: metadata, events: [
            .init(documentID: metadata.id, sequence: 1, payload: .strokeBegan(strokeID: id, style: .init(),
                transform: .init(viewWidth: 1200, viewHeight: 850, paperWidth: 1200, paperHeight: 850), samples: samples)),
            .init(documentID: metadata.id, sequence: 2, payload: .strokeEnded(strokeID: id, reason: .lifted))
        ])
    }
    nonisolated private func json(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    nonisolated private func receipt(id: String, status: String, hash: String? = nil) -> Data {
        var result: [String: Any] = ["id": id, "status": status, "createdAt": "2026-09-10T01:00:00Z", "updatedAt": "2026-09-10T01:01:00Z", "providerTaskID": UUID().uuidString]
        if let hash { result["resultSHA256"] = hash; result["resultFile"] = "generated.png"; result["resultMimeType"] = "image/png" }
        return json(result)
    }

    func testBridgeAddressRejectsPublicHTTPAndCredentials() throws {
        XCTAssertThrowsError(try BridgeAddress.normalize("http://example.com"))
        XCTAssertThrowsError(try BridgeAddress.normalize("https://user:secret@example.com"))
        XCTAssertThrowsError(try BridgeAddress.normalize("https://example.com/api?token=secret"))
        XCTAssertEqual(try BridgeAddress.normalize("https://example.com/").absoluteString, "https://example.com")
        #if DEBUG
        XCTAssertEqual(try BridgeAddress.normalize("http://192.168.1.10:8787").host, "192.168.1.10")
        #endif
    }

    func testEndToEndClientArchivesOriginalAndValidatedOutputSeparately() async throws {
        let (model, endpoint) = environment(), document = try document()
        try BridgeKeychain.save(String(repeating: "test-device-token_", count: 3), endpoint: endpoint)
        let image = try XCTUnwrap(InkRenderer.artwork(document.replay()).pngData())
        var submittedID: String?, submissions = 0
        BridgeProtocolStub.handler = { [self] request in
            if request.url!.path.hasSuffix("/image") { return (200, image) }
            let id = request.url!.lastPathComponent
            if request.httpMethod == "PUT" { submittedID = id; submissions += 1; return (202, receipt(id: id, status: "PENDING")) }
            if submittedID == nil { return (404, json(["error": ["code": "not_found", "message": "No job"]])) }
            return (200, receipt(id: id, status: "SUCCEEDED", hash: RawDrawingExport.sha256(image)))
        }
        let createdID = await model.create(document: document, endpoint: endpoint, prompt: "A synthetic tree.", participant: nil, researchRecords: [], consent: true)
        let id = try XCTUnwrap(createdID)
        await model.refresh(id)
        let record = try XCTUnwrap(model.records.first)
        XCTAssertEqual(record.remote?.status, "SUCCEEDED"); XCTAssertNotNil(record.downloadedFile)
        XCTAssertEqual(submissions, 1)
        let original = try Data(contentsOf: model.original(record)), generated = try Data(contentsOf: XCTUnwrap(model.generated(record)))
        XCTAssertEqual(RawDrawingExport.sha256(original), record.sourcePNGHash)
        XCTAssertEqual(RawDrawingExport.sha256(generated), record.remote?.resultSHA256)
        let raw = try DrawingJSON.decoder().decode(RawDrawingExport.self, from: Data(contentsOf: model.folder(record).appendingPathComponent("original/raw.json")))
        XCTAssertEqual(raw.events, document.events)
        model.load(); XCTAssertEqual(model.records.first?.id, id)
        await model.export(record); XCTAssertNotNil(model.exportURL)
        let attachment = XCTAttachment(contentsOfFile: try XCTUnwrap(model.exportURL)); attachment.name = "generation-provenance-test.zip"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testOfflineCreateRetainsAuthorizedIntentAndOriginalWithoutResubmission() async throws {
        let (model, endpoint) = environment(), document = try document()
        try BridgeKeychain.save(String(repeating: "offline-test_", count: 4), endpoint: endpoint)
        var submissions = 0
        BridgeProtocolStub.handler = { request in if request.httpMethod == "PUT" { submissions += 1 }; throw URLError(.notConnectedToInternet) }
        let createdID = await model.create(document: document, endpoint: endpoint, prompt: "A synthetic tree.", participant: nil, researchRecords: [], consent: true)
        let id = try XCTUnwrap(createdID)
        await model.refresh(id)
        XCTAssertEqual(submissions, 0)
        XCTAssertEqual(model.records.count, 1); XCTAssertNotNil(model.records[0].localError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.original(model.records[0]).path))
        model.load(); XCTAssertEqual(model.records[0].id, id)
    }

    func testResearchGateAndMissingConsentPreventAnyUpload() async throws {
        let (model, endpoint) = environment(), document = try document()
        let pending = ResearchRecord(configuration: .init(participantCode: "P01", purpose: .pilot, group: .unassigned, visit: .V1a))
        var requests = 0
        BridgeProtocolStub.handler = { _ in requests += 1; throw URLError(.badURL) }
        let blocked = await model.create(document: document, endpoint: endpoint, prompt: "A tree.", participant: "P01", researchRecords: [pending], consent: true)
        let noConsent = await model.create(document: document, endpoint: endpoint, prompt: "A tree.", participant: nil, researchRecords: [], consent: false)
        XCTAssertNil(blocked); XCTAssertNil(noConsent); XCTAssertEqual(requests, 0); XCTAssertTrue(model.records.isEmpty)
    }
}
