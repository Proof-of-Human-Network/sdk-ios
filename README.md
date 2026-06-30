# POHKit — Proof of Human iOS/macOS SDK

Swift Package Manager SDK for the [Proof of Human](https://proofofhuman.ge) network.

**Requirements:** iOS 13+, macOS 10.15+, tvOS 13+, watchOS 6+, Swift 5.9+  
Zero dependencies — built on `URLSession`, Swift Concurrency, and `CryptoKit`.

---

## Installation

### Xcode

**File → Add Package Dependencies** → paste the repository URL → choose version **1.3.0** (or `from: "1.3.0"`).

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/Proof-of-Human-Network/sdk-ios", from: "1.3.0"),
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
let poh = POHClient(
    baseURL: URL(string: "https://proofofhuman.ge")!,
    apiKey:  "your-api-key"          // omit for free tier
)

// Multi-node client — auto-selects the fastest live node
let poh = POHClient(nodes: pohDefaultNodes)
try await poh.connect()              // optional: probe nodes before first call

// Single scan
let result = try await poh.scan("0xabc...")
// result.result: true = human | false = not human | nil = inconclusive

// Scan with AI brain verdict in one call
let sv = try await poh.scanAndVerdict("0xabc...")
print(sv.verdict.verdict ?? "pending")       // "HUMAN" | "AI" | "UNCERTAIN"
print(sv.verdict.confidence ?? 0)
```

### Bulk scans

```swift
// Submit — returns immediately with a job reference
let job = try await poh.scanBulk(["0xaaa...", "0xbbb...", "0xccc..."])

// Poll until done
let final = try await poh.pollJob(job.jobId, options: .init(
    interval:   2,
    onProgress: { print("\($0.percent)%") }
))
print(final.results)

// Stream progress
for try await snap in poh.watchJob(job.jobId) {
    print("\(snap.percent)% (\(snap.done)/\(snap.total))")
}

// Convenience one-liner
let done = try await poh.scanAndWait(["0xaaa...", "0xbbb..."])
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
let ref = try await poh.submitJob(
    "What does vitalik.eth write about on Paragraph?",
    options: .init(budget: 0.5, walletAddress: "poh...", privateKeyPem: myPrivateKey)
)

// Poll until the answer arrives
let result = try await poh.pollJobResult(ref.jobId)
print(result.nlResponse ?? "")

// Convenience: submit and wait in one call
let result = try await poh.askAndWait(
    "Summarise the last 5 posts from mirror.xyz/user.eth",
    askOptions:  .init(budget: 0.5, walletAddress: "poh...", privateKeyPem: myPrivateKey),
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
let ref = try await poh.runCompute("Summarize the top 5 rows", options: .init(
    model: "llama3.1:8b",
    dataset: "some-org/some-dataset", // optional
    budget: 0.5,                      // POH
    walletAddress: "poh...",
    privateKeyPem: myPrivateKey
))
let result = try await poh.pollJobResult(ref.jobId)
print(result.output)
```

Before either of these will work, the wallet's signing key must be registered
with the node once via `registerSigningKey(_:publicKeyPem:proof:)` — the node
has no way to verify a signature for a key it has never seen.

---

## Wallet / Blockchain

All balances and amounts are in **μPOH** (micro-POH).  
1 POH = 1 000 000 000 μPOH.

### Balance and nonce

```swift
let balance = try await poh.getBalance("pohAbc123...")
print(balance.balance)          // Int64, μPOH

let nonceResp = try await poh.getNonce("pohAbc123...")
print(nonceResp.nonce)          // use nonce + 1 when building a tx
```

### Transaction history

```swift
let history = try await poh.getTransactionHistory("pohAbc123...", limit: 50)
for entry in history.entries {
    print(entry.txHash, entry.delta, entry.label)
}
```

### Pending mempool

```swift
let pool = try await poh.getPendingTransactions()
print("\(pool.count) transactions pending")
```

---

## Signing and Transactions

POHKit uses **Ed25519** via CryptoKit. Keys are standard PKCS8 PEM (private) and SPKI PEM (public), compatible with Node.js `crypto`.

### Generate a keypair

```swift
let kp = POHSigning.generateKeyPair()
// kp.signingPrivateKey  — PKCS8 PEM, keep secret
// kp.signingPublicKey   — SPKI PEM, register with the node
```

Store `signingPrivateKey` in the iOS Keychain. Never transmit it.

### Register the public key with the node

You only need to do this once per keypair per wallet address.

```swift
let proof = try POHSigning.createSigningProof(
    walletAddress: "pohAbc123...",
    privateKeyPem: kp.signingPrivateKey
)
try await poh.registerSigningKey(
    "pohAbc123...",
    publicKeyPem: kp.signingPublicKey,
    proof: proof
)
```

### Build and sign a transaction

```swift
let nonceResp = try await poh.getNonce("pohAbc123...")

let tx = POHSigning.buildTransfer(
    from:      "pohAbc123...",
    to:        "pohRecipient...",
    amountPOH: 5.0,              // 5 POH → 5_000_000_000 μPOH
    nonce:     nonceResp.nonce + 1,
    fee:       0,
    memo:      "payment"
)

let signed = try POHSigning.signTransaction(tx, keyPair: kp)
let result = try await poh.submitTransaction(signed)
print(result.txHash, result.queueSize)
```

### Convenience transfer

```swift
let kp = POHSigning.generateKeyPair()
let result = try await poh.transfer(
    from:      "pohAbc123...",
    to:        "pohRecipient...",
    amountPOH: 5.0,
    keyPair:   kp,
    memo:      "tip"
)
print(result.txHash)
```

`transfer()` fetches the nonce, builds, signs, and submits in one call.

### Low-level hash and sign

```swift
// Compute a canonical SHA-256 tx hash
let hash = POHSigning.computeTxHash(
    from: "pohAbc...", to: "pohDef...", amount: 5_000_000_000,
    fee: 0, nonce: 42, timestamp: 1_700_000_000_000, memo: ""
)

// Sign an arbitrary UTF-8 message
let sig = try POHSigning.signData("hello", privateKeyPem: kp.signingPrivateKey)
```

---

## Node Info

```swift
// Basic healthz / node metadata
let info = try await poh.getNodeInfo()
print(info.nodeId, info.version, info.reputation)

// Detailed miner info (gas price, model, queue depth)
let miner = try await poh.getMinerInfo()
print(miner.minerAddress, miner.gasPrice, miner.model)
print(miner.queueLength, miner.reputation)

// Skills available on the node
let skills = try await poh.listSkills()
for skill in skills {
    print(skill.id, skill.description ?? "", skill.feeMin ?? 0)
}
```

---

## Error Handling

```swift
do {
    let result = try await poh.scan("0xabc...")
} catch let err as POHError {
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
| `POHClient(baseURL:apiKey:walletAddress:timeout:)` | Single-node client |
| `POHClient(nodes:apiKey:walletAddress:timeout:)` | Multi-node — picks fastest live node |

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
| `getJobStatus(_:)` | `AskJobStatus` | Lightweight status check |
| `getJobResult(_:)` | `AskJobResult` | Full result (call after done) |
| `pollJobResult(_:options:)` | `AskJobResult` | Poll until answer arrives |
| `askAndWait(_:askOptions:pollOptions:)` | `AskJobResult` | Submit + poll convenience |

### Wallet / Blockchain

| Method | Returns | Description |
|--------|---------|-------------|
| `getBalance(_:)` | `WalletBalance` | Balance in μPOH |
| `getNonce(_:)` | `AccountNonce` | Current nonce; use nonce + 1 for next tx |
| `getTransactionHistory(_:limit:)` | `TxHistoryResult` | Recent tx history |
| `getPendingTransactions()` | `PendingTxResult` | Mempool snapshot |
| `submitTransaction(_:)` | `TxSubmitResult` | Submit a signed `PohTx` |
| `registerSigningKey(_:publicKeyPem:proof:)` | `[String: JSONValue]` | Register Ed25519 public key |
| `transfer(from:to:amountPOH:keyPair:fee:memo:)` | `TxSubmitResult` | Build, sign, submit in one call |

### Signing (POHSigning)

| Method | Returns | Description |
|--------|---------|-------------|
| `generateKeyPair()` | `POHKeyPair` | Fresh Ed25519 keypair |
| `signData(_:privateKeyPem:)` | `String` | Base64 Ed25519 signature |
| `createSigningProof(walletAddress:privateKeyPem:)` | `String` | Proof for key registration |
| `computeTxHash(from:to:amount:fee:nonce:timestamp:memo:)` | `String` | SHA-256 canonical tx hash |
| `buildTransfer(from:to:amountPOH:nonce:fee:memo:)` | `PohTx` | Build unsigned transfer |
| `signTransaction(_:keyPair:)` | `PohTx` | Sign with a `POHKeyPair` |
| `signTransaction(_:privateKeyPem:publicKeyPem:)` | `PohTx` | Sign with raw PEM strings |
| `computeJobPaymentHash(jobId:requesterAddress:minerAddress:amount:nonce:)` | `String` | Canonical hash for a job fee payment (used internally by `submitJob`/`runCompute`) |
| `signJobPayment(jobId:requesterAddress:minerAddress:amount:nonce:privateKeyPem:)` | `(txHash: String, signature: String)` | Sign a job fee payment proof (used internally) |

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
