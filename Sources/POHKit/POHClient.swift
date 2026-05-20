import Foundation

/// Client for the Proof of Human API.
///
/// ```swift
/// let poh = POHClient(baseURL: URL(string: "https://proofofhuman.ge")!)
///
/// // Single scan
/// let result = try await poh.scan("0xabc...")
///
/// // Bulk scan + poll
/// let job   = try await poh.scanBulk(["0xaaa...", "0xbbb..."])
/// let final = try await poh.pollJob(job.jobId)
///
/// // Stream progress
/// for try await snap in poh.watchJob(job.jobId) {
///     print("\(snap.percent)% complete")
/// }
/// ```
public final class POHClient {

    private let baseURL: URL
    private let apiKey:        String?
    private let walletAddress: String?
    private let timeout:       TimeInterval
    private let session:       HTTPSession
    private let encoder:       JSONEncoder
    private let decoder:       JSONDecoder

    // ── Init ───────────────────────────────────────────────────────────────────

    /// Create a new POHClient.
    /// - Parameters:
    ///   - baseURL: Base URL of the POH API (no trailing slash needed).
    ///   - apiKey: API key for the paid tier.
    ///   - walletAddress: Solana wallet address for free-tier request tracking.
    ///   - timeout: Per-request timeout in seconds. Default: 30.
    public convenience init(
        baseURL:       URL,
        apiKey:        String? = nil,
        walletAddress: String? = nil,
        timeout:       TimeInterval = 30
    ) {
        self.init(
            baseURL:       baseURL,
            apiKey:        apiKey,
            walletAddress: walletAddress,
            timeout:       timeout,
            session:       URLSession.shared
        )
    }

    init(
        baseURL:       URL,
        apiKey:        String? = nil,
        walletAddress: String? = nil,
        timeout:       TimeInterval = 30,
        session:       HTTPSession
    ) {
        var url = baseURL.absoluteString
        if url.hasSuffix("/") { url.removeLast() }
        self.baseURL       = URL(string: url)!
        self.apiKey        = apiKey
        self.walletAddress = walletAddress
        self.timeout       = timeout
        self.session       = session

        encoder = JSONEncoder()
        decoder = JSONDecoder()
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

    // ── Internal ───────────────────────────────────────────────────────────────

    private func request<T: Decodable>(
        _ method: String,
        path: String,
        body: (some Encodable)? = nil as String?
    ) async throws -> T {
        guard let url = URL(string: baseURL.absoluteString + path) else {
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
}
