import XCTest
@testable import POHKit

final class POHClientTests: XCTestCase {

    private var mock: MockSession!
    private var client: POHClient!

    override func setUp() {
        mock   = MockSession()
        client = POHClient(
            baseURL: URL(string: "http://mock")!,
            session: mock
        )
    }

    // ── scan ──────────────────────────────────────────────────────────────────

    func testScanDecodesResult() async throws {
        let expected = ScanResult(result: true, brainKey: "key-1", freeScansLeft: 4, source: nil, count: nil)
        try mock.enqueue(body: expected)

        let result = try await client.scan("0xabc")

        XCTAssertEqual(result.result, true)
        XCTAssertEqual(result.brainKey, "key-1")
        XCTAssertEqual(result.freeScansLeft, 4)
    }

    func testScanPostsToCheckerEndpoint() async throws {
        try mock.enqueue(body: ScanResult(result: false, brainKey: nil, freeScansLeft: nil, source: nil, count: nil))

        _ = try await client.scan("0xabc")

        let req = try XCTUnwrap(mock.requestsMade.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertTrue(req.url?.path == "/checker")
    }

    func testScanBodyContainsInput() async throws {
        try mock.enqueue(body: ScanResult(result: nil, brainKey: nil, freeScansLeft: nil, source: nil, count: nil))

        _ = try await client.scan("0xtest")

        let req  = try XCTUnwrap(mock.requestsMade.first)
        let body = try XCTUnwrap(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["input"] as? String, "0xtest")
    }

    // ── scanBulk ──────────────────────────────────────────────────────────────

    func testScanBulkDecodesBulkResult() async throws {
        let expected = BulkScanResult(jobId: "j-42", status: .queued, total: 3, pollUrl: nil, freeScansLeft: nil)
        try mock.enqueue(body: expected)

        let result = try await client.scanBulk(["0xaaa", "0xbbb", "0xccc"])

        XCTAssertEqual(result.jobId, "j-42")
        XCTAssertEqual(result.status, .queued)
        XCTAssertEqual(result.total, 3)
    }

    func testScanBulkBodyContainsArray() async throws {
        try mock.enqueue(body: BulkScanResult(jobId: "j-1", status: .queued, total: 2, pollUrl: nil, freeScansLeft: nil))

        _ = try await client.scanBulk(["0xaaa", "0xbbb"])

        let req  = try XCTUnwrap(mock.requestsMade.first)
        let body = try XCTUnwrap(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let arr  = try XCTUnwrap(json?["input"] as? [String])
        XCTAssertEqual(arr, ["0xaaa", "0xbbb"])
    }

    func testScanBulkThrowsOnEmptyInputs() async {
        await XCTAssertThrowsErrorAsync(try await client.scanBulk([])) { error in
            guard case POHError.emptyInputs = error else {
                return XCTFail("Expected .emptyInputs, got \(error)")
            }
        }
    }

    // ── getJob ────────────────────────────────────────────────────────────────

    func testGetJobDecodesStatus() async throws {
        let fixture = JobStatus.fixture(status: .processing, percent: 50)
        try mock.enqueue(body: fixture)

        let job = try await client.getJob("j-1")

        XCTAssertEqual(job.status, .processing)
        XCTAssertEqual(job.percent, 50)
    }

    // ── pollJob ───────────────────────────────────────────────────────────────

    func testPollJobReturnsWhenDone() async throws {
        try mock.enqueue(body: JobStatus.fixture(status: .processing, done: 1, percent: 50))
        try mock.enqueue(body: JobStatus.fixture(status: .done, done: 2, percent: 100))

        let final = try await client.pollJob("j-1", options: .init(interval: 0.01))

        XCTAssertEqual(final.status, .done)
        XCTAssertEqual(mock.requestsMade.count, 2)
    }

    func testPollJobReturnsOnError() async throws {
        try mock.enqueue(body: JobStatus.fixture(status: .error, done: 0, percent: 0))

        let final = try await client.pollJob("j-1", options: .init(interval: 0.01))

        XCTAssertEqual(final.status, .error)
    }

    func testPollJobThrowsOnTimeout() async throws {
        // Always returns processing — will timeout
        let processing = JobStatus.fixture(status: .processing, done: 0, percent: 0)
        mock.responses = Array(repeating: (try JSONEncoder().encode(processing), 200), count: 10)

        await XCTAssertThrowsErrorAsync(
            try await client.pollJob("j-1", options: .init(interval: 0.01, timeout: 0.02))
        ) { error in
            guard case POHError.jobTimedOut = error else {
                return XCTFail("Expected .jobTimedOut, got \(error)")
            }
        }
    }

    func testPollJobCallsOnProgress() async throws {
        try mock.enqueue(body: JobStatus.fixture(status: .processing, done: 1, percent: 50))
        try mock.enqueue(body: JobStatus.fixture(status: .done,       done: 2, percent: 100))

        var progressCalls: [Double] = []
        _ = try await client.pollJob("j-1", options: .init(
            interval:   0.01,
            onProgress: { progressCalls.append($0.percent) }
        ))

        XCTAssertEqual(progressCalls, [50, 100])
    }

    // ── watchJob ──────────────────────────────────────────────────────────────

    func testWatchJobYieldsSnapshots() async throws {
        try mock.enqueue(body: JobStatus.fixture(status: .processing, done: 1, percent: 33))
        try mock.enqueue(body: JobStatus.fixture(status: .processing, done: 2, percent: 66))
        try mock.enqueue(body: JobStatus.fixture(status: .done,       done: 3, percent: 100))

        var percents: [Double] = []
        for try await snap in client.watchJob("j-1", options: .init(interval: 0.01)) {
            percents.append(snap.percent)
        }

        XCTAssertEqual(percents, [33, 66, 100])
    }

    func testWatchJobCanBreakEarly() async throws {
        // Infinite processing responses
        let snap = try JSONEncoder().encode(JobStatus.fixture(status: .processing, done: 0, percent: 0))
        mock.responses = Array(repeating: (snap, 200), count: 20)

        var count = 0
        for try await _ in client.watchJob("j-1", options: .init(interval: 0.01)) {
            count += 1
            if count >= 3 { break }
        }

        XCTAssertEqual(count, 3)
    }

    // ── getBrainVerdict ───────────────────────────────────────────────────────

    func testGetBrainVerdictDecodes() async throws {
        let verdict = BrainVerdict(
            status: "complete", verdict: true, confidence: 0.92,
            signals: ["balance": 0.8, "tx_count": 0.9], reasoning: "looks human"
        )
        try mock.enqueue(body: verdict)

        let result = try await client.getBrainVerdict(brainKey: "bk-1")

        XCTAssertEqual(result.verdict, true)
        XCTAssertEqual(result.confidence, 0.92)
        XCTAssertEqual(result.reasoning, "looks human")
    }

    // ── getMethods ────────────────────────────────────────────────────────────

    func testGetMethodsDecodesArray() async throws {
        let methods = [
            Method(id: "m1", type: "evm", description: "ETH balance", address: "0x0",
                   method: "balance", score: 5.2, voteCount: 12, chainId: "1", expression: nil),
        ]
        try mock.enqueue(body: methods)

        let result = try await client.getMethods()

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "m1")
        XCTAssertEqual(result[0].type, "evm")
    }

    // ── HTTP errors ───────────────────────────────────────────────────────────

    func testThrowsHTTPErrorOn404() async throws {
        try mock.enqueueError(status: 404, message: "not found")

        await XCTAssertThrowsErrorAsync(try await client.scan("0xabc")) { error in
            guard case POHError.httpError(let code, let msg) = error else {
                return XCTFail("Expected .httpError, got \(error)")
            }
            XCTAssertEqual(code, 404)
            XCTAssertEqual(msg, "not found")
        }
    }

    func testApiKeyIsIncludedInHeader() async throws {
        let keyedClient = POHClient(
            baseURL: URL(string: "http://mock")!,
            apiKey: "test-key-abc",
            session: mock
        )
        try mock.enqueue(body: ScanResult(result: true, brainKey: nil, freeScansLeft: nil, source: nil, count: nil))

        _ = try await keyedClient.scan("0xabc")

        let req = try XCTUnwrap(mock.requestsMade.first)
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "test-key-abc")
    }
}

// ── XCTest async helper ────────────────────────────────────────────────────────

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
