import Foundation
@testable import proofofhuman

// ── Mock HTTP session ──────────────────────────────────────────────────────────

final class MockSession: HTTPSession {
    // Queue of responses consumed in order; last one is repeated if queue runs out.
    var responses: [(data: Data, statusCode: Int)] = []
    private(set) var requestsMade: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestsMade.append(request)
        let entry = responses.isEmpty ? (data: Data(), statusCode: 200) : responses.removeFirst()
        let url   = request.url ?? URL(string: "http://mock")!
        let resp  = HTTPURLResponse(url: url, statusCode: entry.statusCode, httpVersion: nil, headerFields: nil)!
        return (entry.data, resp)
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    func enqueue<T: Encodable>(status: Int = 200, body: T) throws {
        responses.append((try JSONEncoder().encode(body), status))
    }

    func enqueueError(status: Int, message: String) throws {
        let body = ["error": message]
        responses.append((try JSONEncoder().encode(body), status))
    }

    /// Enqueue a raw JSON string — works for types that are not Encodable.
    func enqueueRaw(_ json: String, status: Int = 200) {
        responses.append((data: Data(json.utf8), statusCode: status))
    }
}

// ── Fixture builders ───────────────────────────────────────────────────────────

extension JobStatus {
    static func fixture(
        jobId:   String = "job-1",
        status:  JobStatusCode = .done,
        total:   Int = 2,
        done:    Int = 2,
        percent: Double = 100,
        results: [ScanResultItem] = [
            .init(input: "0xaaa", result: true,  error: nil),
            .init(input: "0xbbb", result: false, error: nil),
        ]
    ) -> Self {
        .init(
            jobId: jobId, status: status, total: total,
            done: done, percent: percent,
            results: results, errors: [],
            createdAt: "2024-01-01T00:00:00Z", completedAt: nil
        )
    }
}

extension ScanResultItem {
    init(input: String, result: Bool?, error: String?) {
        self.init(input: input, result: result, error: error)   // memberwise
    }
}
