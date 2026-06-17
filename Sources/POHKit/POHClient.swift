import Foundation

/// Default public bootstrap nodes for the PoH network.
public let pohDefaultNodes: [URL] = [
    URL(string: "https://bootnode.proofofhuman.ge")!,
    URL(string: "https://proofofhuman.ge")!,
    URL(string: "https://poh.assetux.com")!,
]

/// Client for the Proof of Human API.
///
/// ```swift
/// // Legacy single-node:
/// let poh = POHClient(baseURL: URL(string: "https://proofofhuman.ge")!)
///
/// // Network mode — auto-picks fastest live node:
/// let poh = POHClient(nodes: pohDefaultNodes)
/// try await poh.connect()   // probe nodes; optional but removes latency from first call
///
/// // Single scan
/// let result = try await poh.scan("0xabc...")
/// ```
public final class POHClient {

    private let candidateURLs: [URL]
    private let apiKey:        String?
    private let walletAddress: String?
    private let timeout:       TimeInterval
    private let session:       HTTPSession
    private let encoder:       JSONEncoder
    private let decoder:       JSONDecoder

    /// The node URL currently in use. Set after ``connect()`` or first request.
    public private(set) var activeNode: URL?

    // ── Init ───────────────────────────────────────────────────────────────────

    /// Create a client that targets a single node (legacy / backwards-compatible).
    public convenience init(
        baseURL:       URL,
        apiKey:        String? = nil,
        walletAddress: String? = nil,
        timeout:       TimeInterval = 30
    ) {
        self.init(
            nodes:         [baseURL],
            apiKey:        apiKey,
            walletAddress: walletAddress,
            timeout:       timeout,
            session:       URLSession.shared
        )
    }

    /// Create a client that probes multiple network nodes and uses the fastest.
    /// Falls back to ``pohDefaultNodes`` when *nodes* is empty.
    public convenience init(
        nodes:         [URL]         = pohDefaultNodes,
        apiKey:        String?       = nil,
        walletAddress: String?       = nil,
        timeout:       TimeInterval  = 30
    ) {
        self.init(
            nodes:         nodes.isEmpty ? pohDefaultNodes : nodes,
            apiKey:        apiKey,
            walletAddress: walletAddress,
            timeout:       timeout,
            session:       URLSession.shared
        )
    }

    init(
        nodes:         [URL],
        apiKey:        String?      = nil,
        walletAddress: String?      = nil,
        timeout:       TimeInterval = 30,
        session:       HTTPSession
    ) {
        let cleaned = nodes.map { url -> URL in
            var s = url.absoluteString
            if s.hasSuffix("/") { s.removeLast() }
            return URL(string: s)!
        }
        self.candidateURLs = cleaned
        self.activeNode    = cleaned.count == 1 ? cleaned[0] : nil
        self.apiKey        = apiKey
        self.walletAddress = walletAddress
        self.timeout       = timeout
        self.session       = session
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    // ── Node discovery ─────────────────────────────────────────────────────────

    /// Probe all candidate nodes in parallel; resolve ``activeNode`` to the fastest one.
    /// Safe to call multiple times; resolves immediately after the first successful probe.
    ///
    /// Call this once at app start to avoid adding latency to the first scan request.
    public func connect() async {
        guard candidateURLs.count > 1, activeNode == nil else { return }
        await withTaskGroup(of: URL?.self) { group in
            for url in candidateURLs {
                group.addTask { await self.probeNode(url) }
            }
            for await result in group {
                if let url = result, self.activeNode == nil {
                    self.activeNode = url
                    group.cancelAll()
                    return
                }
            }
        }
        if activeNode == nil { activeNode = candidateURLs[0] }
    }

    private func probeNode(_ url: URL) async -> URL? {
        var req = URLRequest(
            url:              URL(string: url.absoluteString + "/healthz")!,
            timeoutInterval:  4
        )
        req.httpMethod = "HEAD"
        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode < 500
        else { return nil }
        return url
    }

    private func resolvedBase() async -> URL {
        if let node = activeNode { return node }
        await connect()
        return activeNode ?? candidateURLs[0]
    }

    // ── Scan ───────────────────────────────────────────────────────────────────

    /// Scan a single wallet address synchronously.
    ///
    /// - Returns: `result` is `true` (human), `false` (not human), or `nil` (inconclusive).
    public func scan(_ input: String, options: ScanOptions = .init()) async throws -> ScanResult {
        let body = CheckerBody(
            input:         .single(input),
            walletAddress: walletAddress,
            chainIds:      options.chainIDs,
            txHash:        options.txHash
        )
        return try await request("POST", path: "/checker", body: body)
    }

    /// Submit a bulk scan for multiple addresses.
    /// Returns a job reference; use ``pollJob(_:options:)`` or ``watchJob(_:options:)`` for results.
    public func scanBulk(_ inputs: [String], options: ScanOptions = .init()) async throws -> BulkScanResult {
        guard !inputs.isEmpty else { throw POHError.emptyInputs }
        let body = CheckerBody(
            input:         .multiple(inputs),
            walletAddress: walletAddress,
            chainIds:      options.chainIDs,
            txHash:        options.txHash
        )
        return try await request("POST", path: "/checker", body: body)
    }

    // ── Job polling ────────────────────────────────────────────────────────────

    /// Fetch the current status snapshot of an async scan job.
    public func getJob(_ jobId: String) async throws -> JobStatus {
        return try await request("GET", path: "/checker/job/\(encoded(jobId))")
    }

    /// Poll a job until it reaches `done` or `error`, then return the final status.
    ///
    /// ```swift
    /// let final = try await poh.pollJob(jobId, options: .init(
    ///     interval:   2,
    ///     onProgress: { print("\($0.percent)%") }
    /// ))
    /// ```
    public func pollJob(_ jobId: String, options: PollOptions = .init()) async throws -> JobStatus {
        let deadline = Date().addingTimeInterval(options.timeout)

        while true {
            let job = try await getJob(jobId)
            options.onProgress?(job)
            if job.status == .done || job.status == .error { return job }
            let nextPoll = Date().addingTimeInterval(options.interval)
            if nextPoll > deadline {
                throw POHError.jobTimedOut(jobId: jobId, lastStatus: job.status.rawValue)
            }
            try await Task.sleep(nanoseconds: UInt64(options.interval * 1_000_000_000))
        }
    }

    /// Async stream that yields a ``JobStatus`` snapshot on every poll interval
    /// until the job is `done` or `error`.
    ///
    /// The caller can `break` early; the stream closes cleanly.
    ///
    /// ```swift
    /// for try await snap in poh.watchJob(jobId) {
    ///     print("\(snap.percent)% (\(snap.done)/\(snap.total))")
    /// }
    /// ```
    public func watchJob(
        _ jobId: String,
        options: PollOptions = .init()
    ) -> AsyncThrowingStream<JobStatus, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let deadline = Date().addingTimeInterval(options.timeout)
                do {
                    while true {
                        let job = try await self.getJob(jobId)
                        continuation.yield(job)
                        if job.status == .done || job.status == .error {
                            continuation.finish()
                            return
                        }
                        let nextPoll = Date().addingTimeInterval(options.interval)
                        if nextPoll > deadline {
                            throw POHError.jobTimedOut(
                                jobId: jobId,
                                lastStatus: job.status.rawValue
                            )
                        }
                        try await Task.sleep(
                            nanoseconds: UInt64(options.interval * 1_000_000_000)
                        )
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Convenience: submit a bulk scan and wait for all results in one call.
    ///
    /// ```swift
    /// let done = try await poh.scanAndWait(["0xaaa...", "0xbbb..."])
    /// print(done.results)
    /// ```
    public func scanAndWait(
        _ inputs: [String],
        scanOptions: ScanOptions = .init(),
        pollOptions: PollOptions = .init()
    ) async throws -> JobStatus {
        let job = try await scanBulk(inputs, options: scanOptions)
        return try await pollJob(job.jobId, options: pollOptions)
    }

    // ── Brain verdict ──────────────────────────────────────────────────────────

    /// Retrieve the AI brain verdict for a completed scan.
    /// `brainKey` is returned by ``scan(_:options:)`` once evaluation finishes.
    public func getBrainVerdict(brainKey: String) async throws -> BrainVerdict {
        return try await request("GET", path: "/checker/brain/\(encoded(brainKey))")
    }

    /// Poll the brain verdict until ``BrainVerdict/status`` leaves `"pending"`.
    ///
    /// Throws ``POHError/jobTimedOut(jobId:lastStatus:)`` if the verdict does not
    /// resolve within `options.timeout` seconds.
    ///
    /// ```swift
    /// let verdict = try await poh.pollBrainVerdict(brainKey: scan.brainKey!)
    /// print(verdict.verdict, verdict.confidence)
    /// ```
    public func pollBrainVerdict(
        brainKey: String,
        options: BrainPollOptions = .init()
    ) async throws -> BrainVerdict {
        let deadline = Date().addingTimeInterval(options.timeout)

        while true {
            let v = try await getBrainVerdict(brainKey: brainKey)
            if v.status != "pending" { return v }
            let nextPoll = Date().addingTimeInterval(options.interval)
            if nextPoll > deadline {
                throw POHError.jobTimedOut(jobId: brainKey, lastStatus: v.status)
            }
            try await Task.sleep(nanoseconds: UInt64(options.interval * 1_000_000_000))
        }
    }

    /// Convenience: scan a single address and wait for the AI brain verdict.
    ///
    /// Returns a ``ScanWithVerdict`` containing both the raw scan evidence and the
    /// resolved verdict.
    ///
    /// ```swift
    /// let sv = try await poh.scanAndVerdict("0xabc...")
    /// print(sv.verdict.verdict, sv.verdict.confidence)
    /// ```
    public func scanAndVerdict(
        _ input: String,
        scanOptions:  ScanOptions     = .init(),
        brainOptions: BrainPollOptions = .init()
    ) async throws -> ScanWithVerdict {
        let scan = try await self.scan(input, options: scanOptions)
        guard let key = scan.brainKey else {
            return ScanWithVerdict(
                scan:    scan,
                verdict: BrainVerdict(status: "not_found", verdict: nil, confidence: nil, signals: nil, reasoning: nil)
            )
        }
        let verdict = try await pollBrainVerdict(brainKey: key, options: brainOptions)
        return ScanWithVerdict(scan: scan, verdict: verdict)
    }

    // ── Methods ────────────────────────────────────────────────────────────────

    /// List all available signal verification methods, ordered by vote score.
    /// - Parameter walletAddress: Override the client-level wallet to annotate your vote history.
    public func getMethods(walletAddress: String? = nil) async throws -> [Method] {
        let addr = walletAddress ?? self.walletAddress
        let qs   = addr.map { "?address=\(encoded($0))" } ?? ""
        return try await request("GET", path: "/verifyer\(qs)")
    }

    /// Fetch a single signal method by its ID.
    public func getMethod(_ methodId: String) async throws -> Method {
        return try await request("GET", path: "/verifyer/\(encoded(methodId))")
    }

    // ── Natural language jobs ─────────────────────────────────────────────────

    /// Submit a natural language question to the PoH network.
    /// Automatically routes the question to the best available skill.
    ///
    /// Returns immediately with an ``AskJobRef``; use ``pollJobResult(_:options:)``
    /// or ``askAndWait(_:askOptions:pollOptions:)`` to wait for the answer.
    ///
    /// - Throws: ``POHError/httpError(statusCode:message:)`` with status 422 if no skill matches.
    public func submitJob(_ question: String, options: AskOptions = .init()) async throws -> AskJobRef {
        let maxBudget = Int64(options.budget * 1_000_000_000)

        // 1. Route the question to a skill
        let routeBody: [String: Any] = ["message": question, "budget": maxBudget]
        let route: ChatRouteResponse = try await requestAny("POST", path: "/chat/route", anyBody: routeBody)
        guard route.type == "skill", let skillId = route.skillId else {
            throw POHError.httpError(statusCode: 422, message: "No skill available for: \"\(question)\"")
        }

        // 2. Submit the job
        var jobBody: [String: Any] = [
            "type": "skill",
            "skillId": skillId,
            "payload": encodeJSONValue(route.input) ?? [:],
            "maxBudget": maxBudget,
        ]
        if let addr = options.walletAddress { jobBody["requesterAddress"] = addr }
        return try await requestAny("POST", path: "/job", anyBody: jobBody)
    }

    /// Fetch the current status of a job (without fetching the full result).
    public func getJobStatus(_ jobId: String) async throws -> AskJobStatus {
        return try await request("GET", path: "/job/\(encoded(jobId))/status")
    }

    /// Fetch the result of a completed job.
    /// Returns a result with `status = "computing"` if the job is not done yet.
    public func getJobResult(_ jobId: String) async throws -> AskJobResult {
        let raw: JobResultEnvelope = try await request("GET", path: "/job/\(encoded(jobId))/result")
        return AskJobResult(
            jobId:      raw.jobId,
            status:     raw.status ?? "computing",
            output:     raw.profile?.skillOutput,
            nlResponse: raw.profile?.nlResponse,
            skillId:    raw.profile?.skillId,
            tokensUsed: raw.profile?.tokensUsed,
            error:      raw.error
        )
    }

    /// Poll a job until it reaches a terminal state (`done` or `error`).
    ///
    /// ```swift
    /// let result = try await poh.pollJobResult(ref.jobId)
    /// print(result.output)
    /// ```
    public func pollJobResult(
        _ jobId: String,
        options: BrainPollOptions = .init()
    ) async throws -> AskJobResult {
        let deadline = Date().addingTimeInterval(options.timeout)
        while true {
            let status = try await getJobStatus(jobId)
            if status.status == "done" || status.status == "error" {
                return try await getJobResult(jobId)
            }
            let nextPoll = Date().addingTimeInterval(options.interval)
            if nextPoll > deadline {
                throw POHError.jobTimedOut(jobId: jobId, lastStatus: status.status)
            }
            try await Task.sleep(nanoseconds: UInt64(options.interval * 1_000_000_000))
        }
    }

    /// Convenience: submit a question and wait for the answer in one call.
    ///
    /// ```swift
    /// let result = try await poh.askAndWait(
    ///     "What does vitalik.eth write about on Paragraph?",
    ///     askOptions: .init(budget: 0.5, walletAddress: "poh...")
    /// )
    /// ```
    public func askAndWait(
        _ question: String,
        askOptions:  AskOptions       = .init(),
        pollOptions: BrainPollOptions = .init()
    ) async throws -> AskJobResult {
        let ref = try await submitJob(question, options: askOptions)
        return try await pollJobResult(ref.jobId, options: pollOptions)
    }

    // ── Node info ──────────────────────────────────────────────────────────────

    /// Fetch metadata about the currently connected node.
    /// Returns node ID, version, wallet address, reputation, and peer count.
    public func getNodeInfo() async throws -> NodeInfo {
        return try await request("GET", path: "/healthz")
    }

    /// List all skills available on the connected node.
    public func listSkills() async throws -> [Skill] {
        return try await request("GET", path: "/api/skills")
    }

    // ── Wallet / blockchain ──────────────────────────────────────────────────────

    /// Fetch the POH balance for *address*.
    /// The balance is in μPOH (1 POH = 1 000 000 000 μPOH).
    public func getBalance(_ address: String) async throws -> WalletBalance {
        return try await request("GET", path: "/api/wallet/balance?address=\(encoded(address))")
    }

    /// Fetch the current nonce for *address*.
    /// Increment by 1 when building a new transaction.
    public func getNonce(_ address: String) async throws -> AccountNonce {
        return try await request("GET", path: "/api/wallet/nonce?address=\(encoded(address))")
    }

    /// Fetch the transaction history for *address*.
    public func getTransactionHistory(_ address: String, limit: Int = 30) async throws -> TxHistoryResult {
        return try await request("GET", path: "/api/wallet/history?address=\(encoded(address))&limit=\(limit)")
    }

    /// Fetch all pending transactions in the mempool.
    public func getPendingTransactions() async throws -> PendingTxResult {
        return try await request("GET", path: "/api/tx/pending")
    }

    /// Submit a pre-signed ``PohTx`` to the network.
    public func submitTransaction(_ tx: PohTx) async throws -> TxSubmitResult {
        return try await request("POST", path: "/api/tx/submit", body: tx)
    }

    /// Register a signing public key for *address* on the node.
    ///
    /// - Parameters:
    ///   - address:      The wallet address to register the key for.
    ///   - publicKeyPem: SPKI PEM public key from ``POHSigning/generateKeyPair()``.
    ///   - proof:        Signature of *address* — from ``POHSigning/createSigningProof(_:privateKeyPem:)``.
    @discardableResult
    public func registerSigningKey(_ address: String, publicKeyPem: String, proof: String) async throws -> [String: JSONValue] {
        let body = RegisterKeyBody(address: address, signingPublicKey: publicKeyPem, proof: proof)
        return try await request("POST", path: "/api/wallet/register-key", body: body)
    }

    /// Fetch detailed information about the connected miner node.
    public func getMinerInfo() async throws -> MinerInfo {
        return try await request("GET", path: "/api/miner/info")
    }

    /// Convenience: build, sign, and submit a POH transfer in one call.
    ///
    /// ```swift
    /// let kp     = POHSigning.generateKeyPair()
    /// let result = try await poh.transfer(
    ///     from:      myAddress,
    ///     to:        recipientAddress,
    ///     amountPOH: 5.0,
    ///     keyPair:   kp
    /// )
    /// ```
    public func transfer(
        from: String,
        to: String,
        amountPOH: Double,
        keyPair: POHKeyPair,
        fee: Int64 = 0,
        memo: String = ""
    ) async throws -> TxSubmitResult {
        let nonceResp = try await getNonce(from)
        let tx        = POHSigning.buildTransfer(from: from, to: to, amountPOH: amountPOH, nonce: nonceResp.nonce + 1, fee: fee, memo: memo)
        let signed    = try POHSigning.signTransaction(tx, keyPair: keyPair)
        return try await submitTransaction(signed)
    }

    // ── Internal ───────────────────────────────────────────────────────────────

    private func request<T: Decodable>(
        _ method: String,
        path: String,
        body: (some Encodable)? = nil as String?
    ) async throws -> T {
        let base = await resolvedBase()
        guard let url = URL(string: base.absoluteString + path) else {
            throw POHError.invalidBaseURL
        }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method

        if let body {
            req.httpBody = try encoder.encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let apiKey {
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch let err as URLError where err.code == .timedOut {
            throw POHError.requestTimeout
        }

        guard let http = response as? HTTPURLResponse else {
            throw POHError.httpError(statusCode: 0, message: "No HTTP response")
        }

        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.error
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw POHError.httpError(statusCode: http.statusCode, message: msg)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw POHError.decodingError(error)
        }
    }

    private func encoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    // Encode a JSONValue back to a plain Any for use in request bodies
    private func encodeJSONValue(_ value: JSONValue?) -> Any? {
        guard let value = value else { return nil }
        switch value {
        case .null:         return NSNull()
        case .bool(let v):  return v
        case .int(let v):   return v
        case .double(let v):return v
        case .string(let v):return v
        case .array(let a): return a.map { encodeJSONValue($0) as Any }
        case .object(let o):return o.mapValues { encodeJSONValue($0) as Any }
        }
    }

    // Request with Any-typed body (serialized via JSONSerialization, not Codable)
    private func requestAny<T: Decodable>(
        _ method: String,
        path: String,
        anyBody: [String: Any]
    ) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: anyBody)
        let base = await resolvedBase()
        guard let url = URL(string: base.absoluteString + path) else {
            throw POHError.invalidBaseURL
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { req.setValue(apiKey, forHTTPHeaderField: "x-api-key") }

        let (respData, response): (Data, URLResponse)
        do {
            (respData, response) = try await session.data(for: req)
        } catch let err as URLError where err.code == .timedOut {
            throw POHError.requestTimeout
        }
        guard let http = response as? HTTPURLResponse else {
            throw POHError.httpError(statusCode: 0, message: "No HTTP response")
        }
        // 202 = job not ready yet — still decode as T
        guard (200..<300).contains(http.statusCode) || http.statusCode == 202 else {
            let msg = (try? JSONDecoder().decode(APIErrorBody.self, from: respData))?.error
                ?? String(data: respData, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw POHError.httpError(statusCode: http.statusCode, message: msg)
        }
        do {
            return try decoder.decode(T.self, from: respData)
        } catch {
            throw POHError.decodingError(error)
        }
    }
}

// ── Private request/response types ───────────────────────────────────────────

private struct RegisterKeyBody: Encodable {
    let address: String
    let signingPublicKey: String
    let proof: String
}

// ── Private response types for natural language job routing ───────────────────

private struct ChatRouteResponse: Decodable {
    let type: String
    let skillId: String?
    let input: JSONValue?
    let reason: String?
}

private struct JobResultEnvelope: Decodable {
    let jobId: String
    let status: String?
    let verdict: String?
    struct Profile: Decodable {
        let skillOutput: JSONValue?
        let nlResponse: String?
        let skillId: String?
        let tokensUsed: Int?
    }
    let profile: Profile?
    let error: String?
}
