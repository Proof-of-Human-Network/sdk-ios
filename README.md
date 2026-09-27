# POHKit — Decentralized Artificial Intelligence iOS/macOS SDK

Swift Package Manager SDK for the [Decentralized Artificial Intelligence](https://iamai.kg) network.

**Requirements:** iOS 15+, macOS 12+, tvOS 15+, watchOS 8+, Swift 5.9+  
Zero dependencies — built on `URLSession`, Swift Concurrency, and `CryptoKit`.

---

## Installation

### Xcode

**File → Add Package Dependencies** → paste the repository URL → choose version **1.6.0** (or `from: "1.6.0"`).

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/Proof-of-Human-Network/sdk-ios", from: "1.6.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "POHKit", package: "sdk-ios")]),
]
```

---

## Quick Start — Scan

```swift
import POHKit

// Single-node client
let dai = POHClient(
    baseURL: URL(string: "https://iamai.kg")!,
    apiKey:  "your-api-key"          // omit for free tier
)

// Multi-node client — auto-selects the fastest live node
let dai = POHClient(nodes: daiDefaultNodes)
try await dai.connect()              // optional: probe nodes before first call

// Local miner routing — write operations (any non-GET request except
// POST /gossip) must go to a node you control. Pass localBaseURL to route
// them to your local miner while reads still use the public nodes; without
// it, writes to a non-loopback node fail with a 403 DAIError.httpError.
let dai = POHClient(nodes: daiDefaultNodes, localBaseURL: URL(string: "http://127.0.0.1:3456")!)

// Single scan
let result = try await dai.scan("0xabc...")
// result.result: true = human | false = not human | nil = inconclusive

// Scan with AI brain verdict in one call
let sv = try await dai.scanAndVerdict("0xabc...")
print(sv.verdict.verdict ?? "pending")       // "HUMAN" | "AI" | "UNCERTAIN"
print(sv.verdict.confidence ?? 0)
```

### Bulk scans

```swift
// Submit — returns immediately with a job reference
let job = try await dai.scanBulk(["0xaaa...", "0xbbb...", "0xccc..."])

// Poll until done
let final = try await dai.pollJob(job.jobId, options: .init(
    interval:   2,
    onProgress: { print("\($0.percent)%") }
))
print(final.results)

// Stream progress
for try await snap in dai.watchJob(job.jobId) {
    print("\(snap.percent)% (\(snap.done)/\(snap.total))")
}

// Convenience one-liner
let done = try await dai.scanAndWait(["0xaaa...", "0xbbb..."])
```

---

## Natural Language Jobs

Ask the network a free-form question; the node routes it to the best skill automatically.

Skill jobs always require a fee — pass `budget`, `walletAddress`, and
`privateKeyPem` on `AskOptions` so the SDK can sign the payment. The node
verifies the signature and debits the fee before it will run the job at all;
it rejects the request outright (no job ever runs) without a valid signed
payment.

```swift
// Fire and forget — returns a job reference
let ref = try await dai.submitJob(
    "What does vitalik.eth write about on Paragraph?",
    options: .init(budget: 0.5, walletAddress: "dai...", privateKeyPem: myPrivateKey)
)

// Poll until the answer arrives
let result = try await dai.pollJobResult(ref.jobId)
print(result.nlResponse ?? "")

// Convenience: submit and wait in one call
let result = try await dai.askAndWait(
    "Summarise the last 5 posts from mirror.xyz/user.eth",
    askOptions:  .init(budget: 0.5, walletAddress: "dai...", privateKeyPem: myPrivateKey),
    pollOptions: .init(timeout: 60)
)
print(result.output)      // skill-specific structured output
print(result.nlResponse)  // natural language summary
```

## Compute Jobs (your own model + dataset)

Run inference with a model of your choice, optionally grounded in a Hugging
Face dataset already installed on the node. Like skill jobs, compute jobs are
never free — `runCompute` always signs a fee payment.

```swift
let ref = try await dai.runCompute("Summarize the top 5 rows", options: .init(
    model: "llama3.1:8b",
    dataset: "some-org/some-dataset", // optional
    budget: 0.5,                      // DAI
    walletAddress: "dai...",
    privateKeyPem: myPrivateKey
))
let result = try await dai.pollJobResult(ref.jobId)
print(result.output)
```

Before either of these will work, the wallet's signing key must be registered
with the node once via `registerSigningKey(_:publicKeyPem:proof:)` — the node
has no way to verify a signature for a key it has never seen.

---

## Estimating a job's fee

Before paying for a job, ask the node what it will cost — the `eth_estimateGas` of
DAI. Send the same fields you would submit (prompt, attachments, a skill, MCP tools, a
dataset). The node sizes the whole pipeline — attachment text, skill and MCP output, dataset
rows, planner and synthesis calls — and returns the AI tokens it will use, the **minimum fee
it accepts**, and a **recommended budget**. It is read-only: nothing runs and nothing is paid.

```swift
let est = try await dai.estimate(
    "Summarize this report and compare it with the latest news",
    options: .init(
        attachments: [ChatAttachment(name: "report.md", content: reportText)]   // text is inlined and measured
        // skillId: "web_search", mcp: ["shop__search"], dataset: "some-org/some-dataset",
        // currency: "aiKGS", maxOutputTokens: 512, route: false
    )
)

est.fees.minimum.raw        // Int64? — μDAI the node will accept, at minimum
est.fees.recommended.raw    // μDAI to escrow — covers the worst case
est.tokens.total            // TokenRange(min:max:)
est.breakdown               // what each part contributed, and how sure that is

// runCompute takes DAI; estimate returns μDAI
let budgetDai = Double(est.fees.recommended.raw ?? 0) / 1e9
```

What comes back:

| Field | Meaning |
|---|---|
| `tokens` | `prompt`, `output`, `skillCompute` and `total`, each a `{min, max}` range |
| `breakdown` | Every contributor, tagged `measured` (counted exactly — prompt, attachment text, dataset rows), `bounded` (capped by the executing code — what a skill fetched, an MCP tool returned) or `assumed` |
| `calls` | Each model call the pipeline makes (planner, skill answer, synthesis…) |
| `fees.minimum` | The lowest fee the node accepts — bids below it are rejected (`/job` floors at a fixed amount, chat at the prompt alone) |
| `fees.recommended` | Covers the pipeline's worst case, never below the minimum. Escrow this |
| `route` | Which pipeline would run; `predicted: true` means it comes from the deterministic router — the live model-planner may choose differently |
| `outputCap`, `warnings` | Whether the budget caps output, and anything unusual (images are not billed; job output is capped at 512 tokens) |

Amounts are in raw units of the fee currency (**μDAI** for DAI; 1 DAI = 1e9 μDAI), so divide by
1e9 for `runCompute`'s `budget`. For a non-DAI `currency` the price is quoted off the live P2P
book; if nothing quotes that pair the quote says `unavailable` instead of inventing a number,
and a DAI figure is returned alongside.

Needs a node newer than 0.4.36 (it adds `POST /api/estimate`); older nodes answer 404.
`estimate` is read-only, so — unlike the other POST methods — it works against remote nodes
without a `localBaseURL`.

## Wallet / Blockchain

All balances and amounts are in **μDAI** (micro-DAI).  
1 DAI = 1 000 000 000 μDAI.

### Balance and nonce

```swift
let balance = try await dai.getBalance("daiAbc123...")
print(balance.balance)          // Int64, μDAI

let nonceResp = try await dai.getNonce("daiAbc123...")
print(nonceResp.nonce)          // use nonce + 1 when building a tx
```

### Transaction history

```swift
let history = try await dai.getTransactionHistory("daiAbc123...", limit: 50)
for entry in history.entries {
    print(entry.txHash, entry.delta, entry.label)
}
```

### Pending mempool

```swift
let pool = try await dai.getPendingTransactions()
print("\(pool.count) transactions pending")
```

---

## Signing and Transactions

POHKit uses **Ed25519** via CryptoKit. Keys are standard PKCS8 PEM (private) and SPKI PEM (public), compatible with Node.js `crypto`.

### Generate a keypair

```swift
let kp = DAISigning.generateKeyPair()
// kp.signingPrivateKey  — PKCS8 PEM, keep secret
// kp.signingPublicKey   — SPKI PEM, register with the node
```

Store `signingPrivateKey` in the iOS Keychain. Never transmit it.

### Register the public key with the node

You only need to do this once per keypair per wallet address.

```swift
let proof = try DAISigning.createSigningProof(
    walletAddress: "daiAbc123...",
    privateKeyPem: kp.signingPrivateKey
)
try await dai.registerSigningKey(
    "daiAbc123...",
    publicKeyPem: kp.signingPublicKey,
    proof: proof
)

// Or in one call — uses kp.address and builds the proof itself
try await dai.registerKeyPair(kp)

// The address a keypair maps to (from its SPKI PEM public key)
let addr = DAISigning.deriveAddressFromSigningKey(kp.signingPublicKey)
```

**Rotating a key** — replacing an already-registered key requires a rotation
proof signed with the *old* private key:

```swift
let proof = try DAISigning.createRotationProof(
    address: "daiAbc123...",
    newSigningPublicKey: newKp.signingPublicKey,
    existingPrivateKeyPem: oldPrivateKeyPem
)
try await dai.registerKeyPair(newKp, rotationProof: proof)
```

### Build and sign a transaction

```swift
let nonceResp = try await dai.getNonce("daiAbc123...")

let tx = DAISigning.buildTransfer(
    from:      "daiAbc123...",
    to:        "daiRecipient...",
    amountDAI: 5.0,              // 5 DAI → 5_000_000_000 μDAI
    nonce:     nonceResp.nonce + 1,
    fee:       0,
    memo:      "payment"
)

let signed = try DAISigning.signTransaction(tx, keyPair: kp)
let result = try await dai.submitTransaction(signed)
print(result.txHash, result.queueSize)
```

### Convenience transfer

```swift
let kp = DAISigning.generateKeyPair()
let result = try await dai.transfer(
    from:      "daiAbc123...",
    to:        "daiRecipient...",
    amountDAI: 5.0,
    keyPair:   kp,
    memo:      "tip"
)
print(result.txHash)
```

`transfer()` fetches the nonce, builds, signs, and submits in one call. It is
pending-aware: when the account has transactions waiting in the mempool it uses
`pendingNonce + 1` (falling back to `nonce + 1`), so back-to-back transfers
don't collide.

### Low-level hash and sign

```swift
// Compute a canonical SHA-256 tx hash
let hash = DAISigning.computeTxHash(
    from: "daiAbc...", to: "daiDef...", amount: 5_000_000_000,
    fee: 0, nonce: 42, timestamp: 1_700_000_000_000, memo: ""
)

// Sign an arbitrary UTF-8 message
let sig = try DAISigning.signData("hello", privateKeyPem: kp.signingPrivateKey)

// Client-side job id ("job-<millis>-<8 hex>") — fee-required jobs must fix the
// id before signing, since the payment proof is bound to it
let jobId = DAISigning.generateJobId()
```

---

## Chat Encryption (DAIChatCrypto)

End-to-end encryption for chat payloads (X25519 + HKDF + AES-256-GCM),
compatible with the node's envelope format.

```swift
// Deterministic X25519 keypair from a stable secret (Data or String)
let ekp = try DAIChatCrypto.deriveEncryptionKeypair(stableSecret)

// Encrypt for a recipient (plaintext as String or Data)
let env = try DAIChatCrypto.seal(recipientPubB64: their.publicKeyB64, plaintext: "hello")

// Decrypt an envelope
let plaintext = try DAIChatCrypto.open(env, privateScalarB64: ekp.privateKeyB64)
```

---

## Node Info

```swift
// Basic healthz / node metadata
let info = try await dai.getNodeInfo()
print(info.nodeId, info.version, info.reputation)

// Detailed miner info (gas price, model, queue depth)
let miner = try await dai.getMinerInfo()
print(miner.minerAddress, miner.gasPrice, miner.model)
print(miner.queueLength, miner.reputation)

// Skills available on the node
let skills = try await dai.listSkills()
for skill in skills {
    print(skill.id, skill.description ?? "", skill.feeMin ?? 0)
}
```

---

## Error Handling

```swift
do {
    let result = try await dai.scan("0xabc...")
} catch let err as DAIError {
    switch err {
    case .httpError(let code, let msg):
        print("API error \(code): \(msg)")
    case .requestTimeout:
        print("Request timed out")
    case .jobTimedOut(let id, let status):
        print("Job \(id) stalled at: \(status)")
    case .decodingError(let underlying):
        print("Decode failed: \(underlying)")
    case .emptyInputs:
        print("Pass at least one address")
    case .invalidBaseURL:
        print("Bad node URL")
    }
}
```

---

## API Reference

### Initializers

| Init | Description |
|------|-------------|
| `POHClient(baseURL:localBaseURL:apiKey:walletAddress:timeout:)` | Single-node client |
| `POHClient(nodes:localBaseURL:apiKey:walletAddress:timeout:)` | Multi-node — picks fastest live node |

`localBaseURL` (optional, both inits): local miner URL that write operations
(any non-GET request except `POST /gossip`) are routed to; reads keep using
the public nodes. Without it, writes to a non-loopback node throw a 403
`DAIError.httpError`.

### Scan

| Method | Returns | Description |
|--------|---------|-------------|
| `scan(_:options:)` | `ScanResult` | Synchronous single-address scan |
| `scanBulk(_:options:)` | `BulkScanResult` | Submit async bulk scan job |
| `getJob(_:)` | `JobStatus` | Fetch job snapshot |
| `pollJob(_:options:)` | `JobStatus` | Poll until done/error |
| `watchJob(_:options:)` | `AsyncThrowingStream<JobStatus>` | Stream job updates |
| `scanAndWait(_:scanOptions:pollOptions:)` | `JobStatus` | Bulk + poll convenience |
| `getBrainVerdict(brainKey:)` | `BrainVerdict` | Fetch AI verdict |
| `pollBrainVerdict(brainKey:options:)` | `BrainVerdict` | Poll until verdict resolves |
| `scanAndVerdict(_:scanOptions:brainOptions:)` | `ScanWithVerdict` | Scan + AI verdict |

### Natural Language Jobs

| Method | Returns | Description |
|--------|---------|-------------|
| `submitJob(_:options:)` | `AskJobRef` | Route and submit a question. Skill jobs always require a fee — pass `budget`, `walletAddress`, `privateKeyPem`. |
| `runCompute(_:options:)` | `AskJobRef` | Submit a job that runs a specific `model` (and optional `dataset`). Always requires a fee. |
| `estimate(_:options:)` | `EstimateResult` | Estimate a job's or chat's fee before paying (`EstimateOptions`) — tokens, minimum fee, recommended budget. Read-only; works on remote nodes. |
| `getJobStatus(_:)` | `AskJobStatus` | Lightweight status check |
| `getJobResult(_:)` | `AskJobResult` | Full result (call after done). Public jobs set `replyCipher` |
| `pollJobResult(_:options:)` | `AskJobResult` | Poll until answer arrives |
| `askAndWait(_:askOptions:pollOptions:)` | `AskJobResult` | Submit + poll convenience |

### Wallet / Blockchain

| Method | Returns | Description |
|--------|---------|-------------|
| `getBalance(_:)` | `WalletBalance` | Balance in μDAI |
| `getNonce(_:)` | `AccountNonce` | Current nonce; use nonce + 1 for next tx |
| `getTransactionHistory(_:limit:)` | `TxHistoryResult` | Recent tx history |
| `getPendingTransactions()` | `PendingTxResult` | Mempool snapshot |
| `submitTransaction(_:)` | `TxSubmitResult` | Submit a signed `DAITx` |
| `registerSigningKey(_:publicKeyPem:proof:rotationProof:)` | `[String: JSONValue]` | Register Ed25519 public key |
| `registerKeyPair(_:rotationProof:)` | `[String: JSONValue]` | Register a `DAIKeyPair` — builds the proof itself |
| `transfer(from:to:amountDAI:keyPair:fee:memo:)` | `TxSubmitResult` | Build, sign, submit in one call (pending-nonce aware) |

### Signing (DAISigning)

| Method | Returns | Description |
|--------|---------|-------------|
| `generateKeyPair()` | `DAIKeyPair` | Fresh Ed25519 keypair |
| `deriveAddressFromSigningKey(_:)` | `String` | `dai…` address from an SPKI PEM public key |
| `signData(_:privateKeyPem:)` | `String` | Base64 Ed25519 signature |
| `createSigningProof(walletAddress:privateKeyPem:)` | `String` | Proof for key registration |
| `createRotationProof(address:newSigningPublicKey:existingPrivateKeyPem:)` | `String` | Proof (signed with the old key) to replace a registered key |
| `computeTxHash(from:to:amount:fee:nonce:timestamp:memo:)` | `String` | SHA-256 canonical tx hash |
| `buildTransfer(from:to:amountDAI:nonce:fee:memo:)` | `DAITx` | Build unsigned transfer |
| `signTransaction(_:keyPair:)` | `DAITx` | Sign with a `DAIKeyPair` |
| `signTransaction(_:privateKeyPem:publicKeyPem:)` | `DAITx` | Sign with raw PEM strings |
| `generateJobId()` | `String` | Client-side job id (`job-<millis>-<8 hex>`) |
| `computeJobPaymentHash(jobId:requesterAddress:minerAddress:amount:nonce:)` | `String` | Canonical hash for a job fee payment (used internally by `submitJob`/`runCompute`) |
| `signJobPayment(jobId:requesterAddress:minerAddress:amount:nonce:privateKeyPem:)` | `(txHash: String, signature: String)` | Sign a job fee payment proof (used internally) |

### Chat Encryption (DAIChatCrypto)

| Method | Returns | Description |
|--------|---------|-------------|
| `deriveEncryptionKeypair(_:)` | `EncryptionKeypair` | Deterministic X25519 keypair from a stable secret (`Data` or `String`) |
| `seal(recipientPubB64:plaintext:)` | `SealedEnvelope` | Encrypt for a recipient (`Data` or `String` plaintext) |
| `open(_:privateScalarB64:)` | `String` | Decrypt a sealed envelope |

### Node Info

| Method | Returns | Description |
|--------|---------|-------------|
| `connect()` | `Void` | Probe nodes, resolve fastest |
| `getNodeInfo()` | `NodeInfo` | Node healthz metadata |
| `getMinerInfo()` | `MinerInfo` | Miner address, gas price, model, queue |
| `listSkills()` | `[Skill]` | Skills available on the node |
| `getMethods(walletAddress:)` | `[Method]` | Signal verification methods |
| `getMethod(_:)` | `Method` | Single method by ID |

---

## License

MIT

## Stablecoins (multi-currency) — protocol notes

The chain now carries five regional stablecoins alongside DAI: `aiGEL`,
`aiKGS`, `aiAMD`, `aiETB`, `aiBTN` (displayed αιGEL …). They use **2 decimals**
(1 unit = 100 raw); DAI keeps 9 (1 DAI = 1e9 μDAI).

Wire protocol (implement when adding native support to this SDK):

- `DAITransaction` gains an optional `currency` field. **Hash preimage rule:**
  `currency` is appended after `memo` in the signed JSON payload ONLY when
  non-DAI — a DAI transaction hashes byte-identically to the historical shape
  and must NOT carry the key at all.
- Job payment hash: `currency` is the SIXTH key of
  `{jobId,requesterAddress,minerAddress,amount,nonce,currency}` ONLY when
  non-DAI.
- `GET /api/assets` lists the registry (tickers, decimals, display names, gas
  prices). `GET /api/wallet/balance` adds `assets: { ticker: {raw, display} }`.
- Job payloads accept `currency`; the miner receives exactly the currency paid.

Native Swift/Kotlin bindings for these fields are NOT yet implemented in this
SDK — see sdk-js (reference implementation) for exact semantics.
