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

/// Present in ``ScanResult/ofac`` when the address is on the OFAC SDN list.
public struct OfacMatch: Decodable {
    public let name:           String
    public let program:        String
    public let chainCode:      String
    /// `"direct"` = scanned address itself; `"counterparty"` = 1-hop tx partner.
    public let type:           String
    public let matchedAddress: String
}

/// Result of a single synchronous scan.
public struct ScanResult: Decodable {
    /// `true` = human, `false` = not human, `nil` = inconclusive.
    public let result: Bool?
    /// Key for fetching the AI brain verdict after evaluation completes.
    public let brainKey: String?
    public let freeScansLeft: Int?
    public let source: String?
    public let count: Int?
    /// Set when the address (or a direct counterparty) is on the OFAC SDN list.
    public let ofac: OfacMatch?
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

// ── Natural language jobs ─────────────────────────────────────────────────────

/// A flexible JSON value for skill outputs whose schema is skill-dependent.
@frozen public enum JSONValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()          { self = .null;                      return }
        if let v = try? c.decode(Bool.self)              { self = .bool(v);   return }
        if let v = try? c.decode(Int.self)               { self = .int(v);    return }
        if let v = try? c.decode(Double.self)            { self = .double(v); return }
        if let v = try? c.decode(String.self)            { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self)       { self = .array(v);  return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON type")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:         try c.encodeNil()
        case .bool(let v):  try c.encode(v)
        case .int(let v):   try c.encode(v)
        case .double(let v):try c.encode(v)
        case .string(let v):try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v):try c.encode(v)
        }
    }
}

public struct AskOptions {
    /// Budget in POH (e.g. 0.5 = 0.5 POH). Converted to μPOH internally.
    public var budget: Double
    /// Wallet address to charge the budget from. Required when budget > 0.
    public var walletAddress: String?
    /// PKCS8 PEM Ed25519 private key used to sign the fee payment. Required when
    /// budget > 0 — skill jobs always require a fee, and the node rejects the job
    /// outright without a valid signed payment proof.
    public var privateKeyPem: String?

    public init(budget: Double = 0, walletAddress: String? = nil, privateKeyPem: String? = nil) {
        self.budget        = budget
        self.walletAddress = walletAddress
        self.privateKeyPem = privateKeyPem
    }
}

/// Options for submitting a paid compute job (user-specified model + dataset).
public struct ComputeOptions {
    /// Which model to run, e.g. "qwen2.5:1.5b", "llama3.1:8b".
    public var model: String
    /// Optional Hugging Face dataset id to ground the answer in (must be installed on the node).
    public var dataset: String?
    /// Fee in POH (e.g. 0.5 = 0.5 POH). Required — compute jobs are never free.
    public var budget: Double
    /// Wallet address paying the fee.
    public var walletAddress: String
    /// PKCS8 PEM Ed25519 private key used to sign the fee payment.
    public var privateKeyPem: String
    /// Optional explicit job id. Auto-generated if omitted.
    public var jobId: String?

    public init(
        model: String, dataset: String? = nil, budget: Double,
        walletAddress: String, privateKeyPem: String, jobId: String? = nil
    ) {
        self.model         = model
        self.dataset       = dataset
        self.budget        = budget
        self.walletAddress = walletAddress
        self.privateKeyPem = privateKeyPem
        self.jobId         = jobId
    }
}

public struct AskJobRef: Decodable {
    public let jobId:     String
    public let status:    String
    public let statusUrl: String?
    public let resultUrl: String?
    public let message:   String?
}

public struct AskJobStatus: Decodable {
    public let jobId:     String
    public let status:    String
    public let error:     String?
    public let updatedAt: String?
}

/// Final result returned after a natural language job completes.
public struct AskJobResult: Decodable {
    public let jobId:      String
    public let status:     String
    /// The skill's answer. Shape is skill-dependent (e.g. read_paragraph → author + posts + analysis).
    public let output:     JSONValue?
    /// Natural language answer generated by the miner's LLM. Present when the job included a question.
    public let nlResponse: String?
    /// Which skill handled the question.
    public let skillId:    String?
    /// Tokens billed for the job.
    public let tokensUsed: Int?
    public let error:      String?
}

// ── Node info ─────────────────────────────────────────────────────────────────

/// Metadata about a PoH miner node.
public struct NodeInfo: Decodable {
    public let status:     String
    public let nodeId:     String?
    public let version:    String?
    public let wallet:     String?
    public let reputation: Double?
    public let uptime:     Int?
    public let peers:      Int?
}

// ── Skills ────────────────────────────────────────────────────────────────────

/// A skill available on the network.
public struct Skill: Decodable, Identifiable {
    public let id:          String
    public let version:     String?
    public let description: String?
    public let triggers:    [String]?
    public let feeMin:      Int?
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

// ── Wallet / blockchain ───────────────────────────────────────────────────────

/// Wallet balance returned by ``POHClient/getBalance(_:)``.
public struct WalletBalance: Decodable {
    public let address: String
    /// Balance in μPOH (1 POH = 1_000_000_000 μPOH).
    public let balance: Int64
}

/// Account nonce returned by ``POHClient/getNonce(_:)``.
/// Increment by 1 when building a new transaction.
public struct AccountNonce: Decodable {
    public let address: String
    public let nonce: Int64
}

/// A single entry in the wallet transaction history.
public struct TxHistoryEntry: Decodable {
    public let height: Int64
    public let delta: Int64
    public let txHash: String
    public let ts: Int64
    public let label: String
}

/// Transaction history returned by ``POHClient/getTransactionHistory(_:limit:)``.
public struct TxHistoryResult: Decodable {
    public let address: String
    public let entries: [TxHistoryEntry]
}

/// A signed or unsigned PoH transaction.
///
/// Build with ``POHSigning/buildTransfer(from:to:amountPOH:nonce:fee:memo:)``,
/// sign with ``POHSigning/signTransaction(_:privateKeyPem:publicKeyPem:)``,
/// then submit with ``POHClient/submitTransaction(_:)``.
public struct PohTx: Codable {
    public let from: String
    public let to: String
    /// Amount in μPOH (1 POH = 1_000_000_000 μPOH).
    public let amount: Int64
    public let fee: Int64
    public let nonce: Int64
    public let timestamp: Int64
    public let memo: String
    public var txHash: String?
    public var signature: String?
    public var signingPublicKey: String?

    enum CodingKeys: String, CodingKey {
        case from, to, amount, fee, nonce, timestamp, memo
        case txHash, signature, signingPublicKey
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        try c.encode(amount, forKey: .amount)
        try c.encode(fee, forKey: .fee)
        try c.encode(nonce, forKey: .nonce)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(memo, forKey: .memo)
        try c.encodeIfPresent(txHash, forKey: .txHash)
        try c.encodeIfPresent(signature, forKey: .signature)
        try c.encodeIfPresent(signingPublicKey, forKey: .signingPublicKey)
    }
}

/// Result returned by ``POHClient/submitTransaction(_:)``.
public struct TxSubmitResult: Decodable {
    public let ok: Bool
    public let txHash: String
    public let queueSize: Int64
}

/// Pending transaction pool returned by ``POHClient/getPendingTransactions()``.
public struct PendingTxResult: Decodable {
    public let txs: [JSONValue]
    public let count: Int64
}

/// Detailed miner information returned by ``POHClient/getMinerInfo()``.
public struct MinerInfo: Decodable {
    public let minerAddress: String
    public let gasPrice: Int64
    public let model: String
    public let queueLength: Int64
    public let reputation: Double
}

/// An Ed25519 keypair for signing PoH transactions.
public struct POHKeyPair {
    /// PKCS8 PEM private key. Keep secret — used to sign transactions.
    public let signingPrivateKey: String
    /// SPKI PEM public key. Register with the node via ``POHClient/registerSigningKey(_:publicKeyPem:proof:)``.
    public let signingPublicKey: String

    public init(signingPrivateKey: String, signingPublicKey: String) {
        self.signingPrivateKey = signingPrivateKey
        self.signingPublicKey  = signingPublicKey
    }
}
