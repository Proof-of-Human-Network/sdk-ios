import Foundation

// ── Options ────────────────────────────────────────────────────────────────────

/// Options passed with every scan request.
public struct ScanOptions {
    /// Restrict evaluation to specific chain IDs, e.g. ["1", "137"].
    public var chainIDs: [String]?
    /// On-chain payment transaction hash (paid tier).
    public var txHash: String?

    public init(chainIDs: [String]? = nil, txHash: String? = nil) {
        self.chainIDs = chainIDs
        self.txHash   = txHash
    }
}

/// Options for brain verdict polling.
public struct BrainPollOptions {
    /// Seconds between brain verdict checks. Default: 1.5
    public var interval: TimeInterval
    /// Maximum total wait in seconds before throwing. Default: 30
    public var timeout: TimeInterval

    public init(interval: TimeInterval = 1.5, timeout: TimeInterval = 30) {
        self.interval = interval
        self.timeout  = timeout
    }
}

/// Combined result of ``POHClient/scanAndVerdict(_:scanOptions:brainOptions:)``.
public struct ScanWithVerdict {
    public let scan:    ScanResult
    public let verdict: BrainVerdict
}

/// Options for job polling and the watch stream.
public struct PollOptions {
    /// Seconds between status checks. Default: 1.5
    public var interval: TimeInterval
    /// Maximum total wait in seconds before throwing. Default: 120
    public var timeout: TimeInterval
    /// Called on every status snapshot while polling.
    public var onProgress: ((JobStatus) -> Void)?

    public init(
        interval: TimeInterval = 1.5,
        timeout:  TimeInterval = 120,
        onProgress: ((JobStatus) -> Void)? = nil
    ) {
        self.interval   = interval
        self.timeout    = timeout
        self.onProgress = onProgress
    }
}

// ── Scan results ───────────────────────────────────────────────────────────────

/// Result of a single synchronous scan.
public struct ScanResult: Decodable {
    /// `true` = human, `false` = not human, `nil` = inconclusive.
    public let result: Bool?
    /// Key for fetching the AI brain verdict after evaluation completes.
    public let brainKey: String?
    public let freeScansLeft: Int?
    public let source: String?
    public let count: Int?
}

/// Reference returned immediately after submitting a bulk scan.
public struct BulkScanResult: Decodable {
    public let jobId: String
    public let status: JobStatusCode
    public let total: Int
    public let pollUrl: String?
    public let freeScansLeft: Int?
}

// ── Job status ─────────────────────────────────────────────────────────────────

public enum JobStatusCode: String, Decodable {
    case queued
    case processing
    case done
    case error
}

/// Per-address result inside a completed job.
public struct ScanResultItem: Decodable {
    public let input: String
    /// `true` = human, `false` = not human, `nil` = inconclusive.
    public let result: Bool?
    public let error: String?
}

/// Full job status snapshot returned by the polling endpoint.
public struct JobStatus: Decodable {
    public let jobId: String
    public let status: JobStatusCode
    public let total: Int
    public let done: Int
    public let percent: Double
    public let results: [ScanResultItem]
    public let errors: [String]
    public let createdAt: String
    public let completedAt: String?
}

// ── AI verdict ─────────────────────────────────────────────────────────────────

/// AI brain verdict returned after scan evaluation finishes.
public struct BrainVerdict: Decodable {
    public let status: String
    /// `"HUMAN"` | `"AI"` | `"UNCERTAIN"` — `nil` while pending.
    public let verdict: String?
    public let confidence: Double?
    public let signals: [String: Double]?
    public let reasoning: String?
}

// ── Methods ────────────────────────────────────────────────────────────────────

/// A registered signal verification method.
public struct Method: Decodable, Identifiable {
    public let id: String
    /// "evm" | "solana" | "rest"
    public let type: String
    public let description: String
    public let address: String?
    public let method: String?
    public let score: Double
    public let voteCount: Int?
    public let chainId: String?
    public let expression: String?
}
