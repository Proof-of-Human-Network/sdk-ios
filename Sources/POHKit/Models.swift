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

/// Combined result of ``DAIClient/scanAndVerdict(_:scanOptions:brainOptions:)``.
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
    /// Budget in DAI (e.g. 0.5 = 0.5 DAI). Converted to μDAI internally.
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

/// Max attachment size accepted by the miner (1 MB).
public let MAX_ATTACHMENT_BYTES = 1 * 1024 * 1024

/// One file attachment for chat/compute (≤1 MB). Prefer `dataUrl` for images.
public struct ChatAttachment {
    public var name: String
    public var mime: String?
    public var content: String?
    public var contentBase64: String?
    public var dataUrl: String?

    public init(
        name: String, mime: String? = nil, content: String? = nil,
        contentBase64: String? = nil, dataUrl: String? = nil
    ) {
        self.name = name
        self.mime = mime
        self.content = content
        self.contentBase64 = contentBase64
        self.dataUrl = dataUrl
    }

    public func asDictionary() -> [String: Any] {
        var d: [String: Any] = ["name": name]
        if let mime { d["mime"] = mime }
        if let content { d["content"] = content }
        if let contentBase64 { d["contentBase64"] = contentBase64 }
        if let dataUrl { d["dataUrl"] = dataUrl }
        return d
    }
}

// ── Fee estimation ────────────────────────────────────────────────────────────

/// Inclusive token bounds. `min == max` when the size is measured exactly.
public struct TokenRange: Decodable, Equatable {
    public let min: Int64
    public let max: Int64
}

/// What to estimate — the same fields a job or chat request carries. Pass the prompt to
/// ``DAIClient/estimate(_:options:)``; everything else is optional.
public struct EstimateOptions {
    /// `"compute"` (default, a paid job), `"chat"` (OpenAI-style `messages`) or `"skill"`.
    public var type: String?
    /// OpenAI-style messages for `type: "chat"` (use this OR a prompt).
    public var messages: [[String: String]]?
    public var history: [[String: String]]?
    /// Text is inlined and measured; images are not billed by the node.
    public var attachments: [ChatAttachment]?
    public var skillId: String?
    /// MCP tool names (`server__tool`) to run in a cascade.
    public var mcp: [String]?
    /// An installed Hugging Face dataset id — the rows the job would inject are measured.
    public var dataset: String?
    /// Fee currency ticker; `nil` for DAI. Non-DAI fees are quoted off the live P2P book.
    public var currency: String?
    /// Output tokens to reserve (1...4096, default 512). Jobs cap output at 512 regardless.
    public var maxOutputTokens: Int?
    /// `false` skips skill/cascade routing, as on a job.
    public var route: Bool
    public var model: String?
    /// Defaults to the client's `walletAddress`.
    public var requesterAddress: String?
    /// The `/job` payload address, if any (it sets the job fee floor).
    public var address: String?

    public init(
        type: String? = nil, messages: [[String: String]]? = nil, history: [[String: String]]? = nil,
        attachments: [ChatAttachment]? = nil, skillId: String? = nil, mcp: [String]? = nil,
        dataset: String? = nil, currency: String? = nil, maxOutputTokens: Int? = nil,
        route: Bool = true, model: String? = nil, requesterAddress: String? = nil, address: String? = nil
    ) {
        self.type = type
        self.messages = messages
        self.history = history
        self.attachments = attachments
        self.skillId = skillId
        self.mcp = mcp
        self.dataset = dataset
        self.currency = currency
        self.maxOutputTokens = maxOutputTokens
        self.route = route
        self.model = model
        self.requesterAddress = requesterAddress
        self.address = address
    }

    func toBody(prompt: String?) -> [String: Any] {
        var b: [String: Any] = [:]
        if let prompt, !prompt.isEmpty { b["prompt"] = prompt }
        if let type { b["type"] = type }
        if let messages, !messages.isEmpty { b["messages"] = messages }
        if let history, !history.isEmpty { b["history"] = history }
        if let attachments, !attachments.isEmpty { b["attachments"] = attachments.map { $0.asDictionary() } }
        if let skillId { b["skillId"] = skillId }
        if let mcp, !mcp.isEmpty { b["mcp"] = mcp }
        if let dataset { b["dataset"] = dataset }
        if let currency { b["currency"] = currency }
        if let maxOutputTokens { b["maxOutputTokens"] = maxOutputTokens }
        if !route { b["route"] = false }
        if let model { b["model"] = model }
        if let requesterAddress { b["requesterAddress"] = requesterAddress }
        if let address { b["address"] = address }
        return b
    }
}

/// One contributor to the prompt, tagged by how well its size is known.
public struct EstimateBreakdownItem: Decodable {
    public let id: String
    public let kind: String
    public let ref: String?
    public let tokens: TokenRange
    /// `"measured"` (counted exactly), `"bounded"` (capped by the executing code) or `"assumed"`.
    public let basis: String
    public let note: String?
}

/// One model call the pipeline makes.
public struct EstimateCall: Decodable {
    public let purpose: String
    public let promptTokens: TokenRange
    public let outputTokens: TokenRange
    public let basis: String?
    public let note: String?
}

/// A fee in one currency. `raw` is `nil` when `unavailable` (nothing quotes that pair).
public struct FeeQuote: Decodable {
    public let tokens: Int64
    /// Raw units of `currency` (μDAI for DAI).
    public let raw: Int64?
    public let currency: String
    /// The endpoint whose floor this is (set on `minimum`).
    public let gate: String?
    public let gasPrice: Double?
    public let source: String?
    public let via: String?
    public let display: Double?
    public let unavailable: Bool?
    public let message: String?
}

public struct EstimateDaiFees: Decodable {
    public let minimum: FeeQuote
    public let recommended: FeeQuote
}

public struct EstimateFees: Decodable {
    public let currency: String
    /// The lowest fee the node accepts — bids below it are rejected.
    public let minimum: FeeQuote
    /// Covers the pipeline's worst case (never below `minimum`). Escrow this.
    public let recommended: FeeQuote
    /// DAI figures, present when `currency` is not DAI.
    public let dai: EstimateDaiFees?
}

public struct EstimateTask: Decodable {
    public let id: String
    public let kind: String
    public let skillId: String?
    public let tool: String?
}

public struct EstimateRoute: Decodable {
    /// `"direct"`, `"routed-skill"`, `"cascade"` or `"skill-job"`.
    public let mode: String
    /// True when the plan comes from the deterministic router; the live model-planner may differ.
    public let predicted: Bool
    public let reason: String?
    public let skillId: String?
    public let tasks: [EstimateTask]?
}

public struct EstimateTokens: Decodable {
    public let prompt: TokenRange
    public let output: TokenRange
    public let skillCompute: TokenRange
    public let total: TokenRange
}

public struct OutputCap: Decodable {
    public let budgetCapApplies: Bool
    public let tokens: Int64?
    public let note: String?
}

/// Reply from ``DAIClient/estimate(_:options:)`` (`POST /api/estimate`).
public struct EstimateResult: Decodable {
    public let type: String
    /// `"job"` (POST /job) or `"chat"` (/v1, /openai/v1) — decides which minimum applies.
    public let target: String
    public let model: String
    public let currency: String
    public let gasPrice: Double
    public let route: EstimateRoute
    public let tokens: EstimateTokens
    public let calls: [EstimateCall]
    public let breakdown: [EstimateBreakdownItem]
    public let fees: EstimateFees
    public let outputCap: OutputCap
    public let warnings: [String]
}

/// Options for free-form chat (`POST /chat/ask`).
public struct ChatOptions {
    public var history: [[String: String]]?
    public var model: String?
    public var privateMode: Bool
    public var attachments: [ChatAttachment]?
    /// Force a dataset after approving a 412 HF_DATASET_DOWNLOAD_REQUIRED.
    public var datasetId: String?
    public var requesterAddress: String?

    public init(
        history: [[String: String]]? = nil, model: String? = nil,
        privateMode: Bool = true, attachments: [ChatAttachment]? = nil,
        datasetId: String? = nil, requesterAddress: String? = nil
    ) {
        self.history = history
        self.model = model
        self.privateMode = privateMode
        self.attachments = attachments
        self.datasetId = datasetId
        self.requesterAddress = requesterAddress
    }
}

/// Reply from ``DAIClient/chat(_:options:)``.
public struct ChatResult: Decodable {
    public let type: String?
    public let message: String
    public let skill: String?
    public let skillId: String?
    public let cascade: Bool?
    public let tasks: Bool?
    public let dataset: String?
    public let datasetId: String?
    public let fromChainHistory: Bool?
    public let code: String?

    enum CodingKeys: String, CodingKey {
        case type, message, skill, skillId, cascade, tasks, dataset, datasetId
        case fromChainHistory, code, reply
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        message = (try c.decodeIfPresent(String.self, forKey: .message))
            ?? (try c.decodeIfPresent(String.self, forKey: .reply))
            ?? ""
        skill = try c.decodeIfPresent(String.self, forKey: .skill)
        skillId = try c.decodeIfPresent(String.self, forKey: .skillId)
        cascade = try c.decodeIfPresent(Bool.self, forKey: .cascade)
        tasks = try c.decodeIfPresent(Bool.self, forKey: .tasks)
        dataset = try c.decodeIfPresent(String.self, forKey: .dataset)
        datasetId = try c.decodeIfPresent(String.self, forKey: .datasetId)
        fromChainHistory = try c.decodeIfPresent(Bool.self, forKey: .fromChainHistory)
        code = try c.decodeIfPresent(String.self, forKey: .code)
    }
}

/// Options for submitting a paid compute job (user-specified model + dataset).
public struct ComputeOptions {
    /// Which model to run, e.g. "qwen3-1.7b", "qwen3vl-2b".
    public var model: String
    /// Optional Hugging Face dataset id to ground the answer in (must be installed on the node).
    public var dataset: String?
    /// Fee in DAI (e.g. 0.5 = 0.5 DAI). Required — compute jobs are never free.
    public var budget: Double
    /// Wallet address paying the fee.
    public var walletAddress: String
    /// PKCS8 PEM Ed25519 private key used to sign the fee payment.
    public var privateKeyPem: String
    /// Optional explicit job id. Auto-generated if omitted.
    public var jobId: String?
    public var history: [[String: String]]?
    public var attachments: [ChatAttachment]?
    /// When false, skip skill/task-cascade auto-routing on the miner.
    public var route: Bool?

    public init(
        model: String, dataset: String? = nil, budget: Double,
        walletAddress: String, privateKeyPem: String, jobId: String? = nil,
        history: [[String: String]]? = nil, attachments: [ChatAttachment]? = nil,
        route: Bool? = nil
    ) {
        self.model         = model
        self.dataset       = dataset
        self.budget        = budget
        self.walletAddress = walletAddress
        self.privateKeyPem = privateKeyPem
        self.jobId         = jobId
        self.history       = history
        self.attachments   = attachments
        self.route         = route
    }
}

/// Installed HF datasets on the miner.
public struct HfDatasetListResult: Decodable {
    public let datasets: [JSONValue]
}

/// MCP server status from the miner.
public struct McpStatusResult: Decodable {
    public let servers: [JSONValue]?
    public let tools: [JSONValue]?
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
    /// True when the reply is sealed in `replyCipher` and `output` is nil.
    public let encrypted:  Bool?
    /// `profile.replyCipher`. Open with the requester X25519 key.
    public let replyCipher: JSONValue?
    public let error:      String?
}

// ── Node info ─────────────────────────────────────────────────────────────────

/// Metadata about a DAI miner node.
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

/// Wallet balance returned by ``DAIClient/getBalance(_:)``.
public struct WalletBalance: Decodable {
    public let address: String
    /// Balance in μDAI (1 DAI = 1_000_000_000 μDAI).
    public let balance: Int64
}

/// Account nonce returned by ``DAIClient/getNonce(_:)``.
/// Increment by 1 when building a new transaction.
public struct AccountNonce: Decodable {
    public let address: String
    public let nonce: Int64
    public let pendingNonce: Int64?
}

/// A single entry in the wallet transaction history.
public struct TxHistoryEntry: Decodable {
    public let height: Int64
    public let delta: Int64
    public let txHash: String
    public let ts: Int64
    public let label: String
}

/// Transaction history returned by ``DAIClient/getTransactionHistory(_:limit:)``.
public struct TxHistoryResult: Decodable {
    public let address: String
    public let entries: [TxHistoryEntry]
}

/// A signed or unsigned DAI transaction.
///
/// Build with ``DAISigning/buildTransfer(from:to:amountDAI:nonce:fee:memo:)``,
/// sign with ``DAISigning/signTransaction(_:privateKeyPem:publicKeyPem:)``,
/// then submit with ``DAIClient/submitTransaction(_:)``.
public struct DAITx: Codable {
    public let from: String
    public let to: String
    /// Amount in μDAI (1 DAI = 1_000_000_000 μDAI).
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

/// Result returned by ``DAIClient/submitTransaction(_:)``.
public struct TxSubmitResult: Decodable {
    public let ok: Bool
    public let txHash: String
    public let queueSize: Int64
}

/// Pending transaction pool returned by ``DAIClient/getPendingTransactions()``.
public struct PendingTxResult: Decodable {
    public let txs: [JSONValue]
    public let count: Int64
}

/// Detailed miner information returned by ``DAIClient/getMinerInfo()``.
public struct MinerInfo: Decodable {
    public let minerAddress: String
    public let gasPrice: Int64
    public let model: String
    public let queueLength: Int64
    public let reputation: Double
}

/// An Ed25519 keypair for signing DAI transactions.
public struct DAIKeyPair {
    /// PKCS8 PEM private key. Keep secret — used to sign transactions.
    public let signingPrivateKey: String
    /// SPKI PEM public key. Register with the node via ``DAIClient/registerSigningKey(_:publicKeyPem:proof:)``.
    public let signingPublicKey: String
    /// Canonical `dai…` address derived from ``signingPublicKey``.
    public let address: String

    public init(signingPrivateKey: String, signingPublicKey: String, address: String) {
        self.signingPrivateKey = signingPrivateKey
        self.signingPublicKey  = signingPublicKey
        self.address           = address
    }
}
