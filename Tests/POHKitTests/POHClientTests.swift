import XCTest
@testable import proofofhuman

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

    // ── getNodeInfo ────────────────────────────────────────────────────────────

    func testGetNodeInfoDecodesMetadata() async throws {
        mock.enqueueRaw(#"{"status":"ok","nodeId":"node-42","version":"1.2.0","peers":3}"#)

        let info = try await client.getNodeInfo()

        XCTAssertEqual(info.nodeId, "node-42")
        XCTAssertEqual(info.version, "1.2.0")
        XCTAssertEqual(info.peers, 3)
    }

    func testGetNodeInfoUsesGetMethod() async throws {
        mock.enqueueRaw(#"{"status":"ok"}"#)

        _ = try await client.getNodeInfo()

        XCTAssertEqual(mock.requestsMade.first?.httpMethod, "GET")
    }

    // ── listSkills ─────────────────────────────────────────────────────────────

    func testListSkillsDecodesArray() async throws {
        mock.enqueueRaw(#"[{"id":"sk-1","description":"Summariser","triggers":["summarise"],"version":"1.0"}]"#)

        let skills = try await client.listSkills()

        XCTAssertEqual(skills.count, 1)
        XCTAssertEqual(skills[0].id, "sk-1")
        XCTAssertEqual(skills[0].description, "Summariser")
    }

    // ── getMinerInfo ───────────────────────────────────────────────────────────

    func testGetMinerInfoDecodesMetadata() async throws {
        mock.enqueueRaw(#"{"minerAddress":"poh-miner-1","gasPrice":1000,"model":"llama-3","queueLength":2,"reputation":4.5}"#)

        let info = try await client.getMinerInfo()

        XCTAssertEqual(info.minerAddress, "poh-miner-1")
        XCTAssertEqual(info.model, "llama-3")
        XCTAssertEqual(info.queueLength, 2)
    }

    // ── getBalance ─────────────────────────────────────────────────────────────

    func testGetBalanceDecodesAddressAndBalance() async throws {
        mock.enqueueRaw(#"{"address":"poh123","balance":5000000000}"#)

        let bal = try await client.getBalance("poh123")

        XCTAssertEqual(bal.address, "poh123")
        XCTAssertEqual(bal.balance, 5_000_000_000)
    }

    func testGetBalanceIncludesAddressInQueryString() async throws {
        mock.enqueueRaw(#"{"address":"poh123","balance":0}"#)

        _ = try await client.getBalance("poh123")

        let url = try XCTUnwrap(mock.requestsMade.first?.url?.absoluteString)
        XCTAssertTrue(url.contains("poh123"))
    }

    // ── getNonce ───────────────────────────────────────────────────────────────

    func testGetNonceDecodesCurrentNonce() async throws {
        mock.enqueueRaw(#"{"address":"poh123","nonce":7}"#)

        let n = try await client.getNonce("poh123")

        XCTAssertEqual(n.address, "poh123")
        XCTAssertEqual(n.nonce, 7)
    }

    // ── getTransactionHistory ──────────────────────────────────────────────────

    func testGetTransactionHistoryDecodesEntries() async throws {
        mock.enqueueRaw("""
            {"address":"poh123","entries":[
                {"height":100,"delta":1000000000,"txHash":"abc","ts":1700000000,"label":"transfer"}
            ]}
        """)

        let hist = try await client.getTransactionHistory("poh123")

        XCTAssertEqual(hist.address, "poh123")
        XCTAssertEqual(hist.entries.count, 1)
        XCTAssertEqual(hist.entries[0].delta, 1_000_000_000)
        XCTAssertEqual(hist.entries[0].label, "transfer")
    }

    // ── getPendingTransactions ─────────────────────────────────────────────────

    func testGetPendingTransactionsDecodesCount() async throws {
        mock.enqueueRaw(#"{"txs":[],"count":0}"#)

        let p = try await client.getPendingTransactions()

        XCTAssertEqual(p.count, 0)
        XCTAssertTrue(p.txs.isEmpty)
    }

    // ── submitTransaction ──────────────────────────────────────────────────────

    func testSubmitTransactionPostsAndReturnsHash() async throws {
        mock.enqueueRaw(#"{"ok":true,"txHash":"cafebabe","queueSize":1}"#)

        let tx = PohTx(
            from: "pohA", to: "pohB", amount: 1_000_000_000, fee: 0,
            nonce: 1, timestamp: 1_700_000_000_000, memo: "",
            txHash: "cafebabe", signature: "sig", signingPublicKey: "pub"
        )
        let result = try await client.submitTransaction(tx)

        XCTAssertEqual(result.txHash, "cafebabe")
        XCTAssertTrue(result.ok)
    }

    func testSubmitTransactionUsesPostMethod() async throws {
        mock.enqueueRaw(#"{"ok":true,"txHash":"abc","queueSize":0}"#)

        let tx = PohTx(
            from: "pohA", to: "pohB", amount: 1_000_000_000, fee: 0,
            nonce: 1, timestamp: 1_700_000_000_000, memo: "",
            txHash: "abc", signature: "sig", signingPublicKey: "pub"
        )
        _ = try await client.submitTransaction(tx)

        XCTAssertEqual(mock.requestsMade.first?.httpMethod, "POST")
    }

    // ── registerSigningKey ─────────────────────────────────────────────────────

    func testRegisterSigningKeyPostsKeyAndProof() async throws {
        mock.enqueueRaw(#"{"success":true}"#)

        _ = try await client.registerSigningKey("pohA", publicKeyPem: "pubkey-pem", proof: "proof-b64")

        let req = try XCTUnwrap(mock.requestsMade.first)
        XCTAssertEqual(req.httpMethod, "POST")
        let body = try XCTUnwrap(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["address"] as? String, "pohA")
        XCTAssertEqual(json?["signingPublicKey"] as? String, "pubkey-pem")
        XCTAssertEqual(json?["proof"] as? String, "proof-b64")
    }

    // ── submitJob ──────────────────────────────────────────────────────────────

    func testSubmitJobRoutesToSkillThenCreatesJob() async throws {
        mock.enqueueRaw(#"{"type":"skill","skillId":"sk-sum","input":{}}"#)
        mock.enqueueRaw(#"{"jobId":"jnl-1","status":"queued","statusUrl":null,"resultUrl":null,"message":null}"#)

        let ref = try await client.submitJob("Summarise this")

        XCTAssertEqual(ref.jobId, "jnl-1")
        XCTAssertEqual(ref.status, "queued")
    }

    func testSubmitJobThrowsWhenNoSkillMatched() async {
        mock.enqueueRaw(#"{"type":"chat","reason":"No skill matched"}"#, status: 422)

        await XCTAssertThrowsErrorAsync(try await client.submitJob("random question")) { error in
            guard case POHError.httpError(let code, _) = error else {
                return XCTFail("Expected .httpError, got \(error)")
            }
            XCTAssertEqual(code, 422)
        }
    }

    func testSubmitJobThrowsWhenBudgetPositiveWithoutPrivateKey() async {
        mock.enqueueRaw(#"{"type":"skill","skillId":"sk-sum","input":{}}"#)

        await XCTAssertThrowsErrorAsync(
            try await client.submitJob("Summarise this", options: .init(budget: 0.5, walletAddress: "pohAlice"))
        ) { error in
            guard case POHError.httpError(let code, _) = error else {
                return XCTFail("Expected .httpError, got \(error)")
            }
            XCTAssertEqual(code, 402)
        }
    }

    func testSubmitJobSignsNonceBoundPaymentProofWhenBudgetPositive() async throws {
        let kp = POHSigning.generateKeyPair()
        mock.enqueueRaw(#"{"type":"skill","skillId":"sk-sum","input":{}}"#)
        mock.enqueueRaw(#"{"minerAddress":"pohMiner","gasPrice":1,"model":"qwen2.5:1.5b","queueLength":0,"reputation":1.0}"#)
        mock.enqueueRaw(#"{"address":"pohAlice","nonce":3}"#)
        mock.enqueueRaw(#"{"jobId":"jnl-1","status":"queued","statusUrl":null,"resultUrl":null,"message":null}"#)

        let ref = try await client.submitJob("Summarise this", options: .init(
            budget: 0.5, walletAddress: "pohAlice", privateKeyPem: kp.signingPrivateKey
        ))

        XCTAssertEqual(ref.jobId, "jnl-1")
        let req  = try XCTUnwrap(mock.requestsMade.last)
        let body = try XCTUnwrap(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["maxBudget"] as? Int64, 500_000_000)
        XCTAssertEqual(json?["requesterAddress"] as? String, "pohAlice")
        let paymentTx = try XCTUnwrap(json?["paymentTx"] as? [String: Any])
        XCTAssertNotNil(paymentTx["txHash"])
        XCTAssertNotNil(paymentTx["signature"])
    }

    // ── runCompute ─────────────────────────────────────────────────────────────

    func testRunComputeThrowsWhenBudgetNotPositive() async throws {
        let kp = POHSigning.generateKeyPair()
        await XCTAssertThrowsErrorAsync(
            try await client.runCompute("hi", options: .init(
                model: "qwen2.5:1.5b", budget: 0, walletAddress: "pohAlice", privateKeyPem: kp.signingPrivateKey
            ))
        ) { error in
            guard case POHError.httpError(let code, _) = error else {
                return XCTFail("Expected .httpError, got \(error)")
            }
            XCTAssertEqual(code, 402)
        }
    }

    func testRunComputeSignsPaymentAndPostsModelDataset() async throws {
        let kp = POHSigning.generateKeyPair()
        mock.enqueueRaw(#"{"minerAddress":"pohMiner","gasPrice":1,"model":"qwen2.5:1.5b","queueLength":0,"reputation":1.0}"#)
        mock.enqueueRaw(#"{"address":"pohAlice","nonce":7}"#)
        mock.enqueueRaw(#"{"jobId":"jc-1","status":"queued","statusUrl":null,"resultUrl":null,"message":null}"#)

        let ref = try await client.runCompute("Summarize the top rows", options: .init(
            model: "llama3.1:8b", dataset: "some-org/some-dataset",
            budget: 0.5, walletAddress: "pohAlice", privateKeyPem: kp.signingPrivateKey
        ))

        XCTAssertEqual(ref.jobId, "jc-1")
        let req  = try XCTUnwrap(mock.requestsMade.last)
        let body = try XCTUnwrap(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "llama3.1:8b")
        XCTAssertEqual(json?["dataset"] as? String, "some-org/some-dataset")
        XCTAssertEqual(json?["maxBudget"] as? Int64, 500_000_000)
        let payload = try XCTUnwrap(json?["payload"] as? [String: Any])
        XCTAssertEqual(payload["prompt"] as? String, "Summarize the top rows")
    }

    // ── getJobStatus ───────────────────────────────────────────────────────────

    func testGetJobStatusDecodesStatus() async throws {
        mock.enqueueRaw(#"{"jobId":"jnl-1","status":"computing","error":null,"updatedAt":null}"#)

        let s = try await client.getJobStatus("jnl-1")

        XCTAssertEqual(s.jobId, "jnl-1")
        XCTAssertEqual(s.status, "computing")
    }

    // ── getJobResult ───────────────────────────────────────────────────────────

    func testGetJobResultParsesCompletedResult() async throws {
        mock.enqueueRaw("""
            {"jobId":"jnl-1","status":"done",
             "output":{"answer":42},"nlResponse":"The answer is 42.",
             "skillId":"sk-1","tokensUsed":10,"error":null}
        """)

        let r = try await client.getJobResult("jnl-1")

        XCTAssertEqual(r.jobId, "jnl-1")
        XCTAssertEqual(r.status, "done")
        XCTAssertEqual(r.nlResponse, "The answer is 42.")
        XCTAssertEqual(r.tokensUsed, 10)
        XCTAssertEqual(r.skillId, "sk-1")
    }

    // ── pollJobResult ──────────────────────────────────────────────────────────

    func testPollJobResultFetchesResultWhenDone() async throws {
        mock.enqueueRaw(#"{"jobId":"jnl-2","status":"done","error":null,"updatedAt":null}"#)
        mock.enqueueRaw("""
            {"jobId":"jnl-2","status":"done",
             "output":null,"nlResponse":"Done!","skillId":"sk-1","tokensUsed":5,"error":null}
        """)

        let r = try await client.pollJobResult("jnl-2", options: .init(interval: 0.01))

        XCTAssertEqual(r.nlResponse, "Done!")
    }

    // ── askAndWait ─────────────────────────────────────────────────────────────

    func testAskAndWaitRoutesSubmitsAndPolls() async throws {
        mock.enqueueRaw(#"{"type":"skill","skillId":"sk-1","input":{}}"#)
        mock.enqueueRaw(#"{"jobId":"jnl-3","status":"queued","statusUrl":null,"resultUrl":null,"message":null}"#)
        mock.enqueueRaw(#"{"jobId":"jnl-3","status":"done","error":null,"updatedAt":null}"#)
        mock.enqueueRaw("""
            {"jobId":"jnl-3","status":"done",
             "output":null,"nlResponse":"Answer","skillId":"sk-1","tokensUsed":8,"error":null}
        """)

        let r = try await client.askAndWait(
            "What is 2+2?",
            askOptions: .init(budget: 0),
            pollOptions: .init(interval: 0.01)
        )

        XCTAssertEqual(r.nlResponse, "Answer")
    }

    // ── getMethod ─────────────────────────────────────────────────────────────

    func testGetMethodDecodesSingleMethod() async throws {
        mock.enqueueRaw("""
            {"id":"m2","type":"solana","description":"SOL staking","score":2.5,"voteCount":12}
        """)

        let m = try await client.getMethod("m2")

        XCTAssertEqual(m.id, "m2")
        XCTAssertEqual(m.type, "solana")
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
