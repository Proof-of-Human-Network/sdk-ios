# POHKit — Proof of Human iOS/macOS SDK

Swift Package Manager SDK for the [Proof of Human](https://proofofhuman.ge) network.

**Requirements:** iOS 15+, macOS 12+, tvOS 15+, watchOS 8+, Swift 5.9+  
Zero dependencies — built on `URLSession`, Swift Concurrency, and `CryptoKit`.

---

## Installation

### Xcode

**File → Add Package Dependencies** → paste the repository URL → choose version **1.5.0** (or `from: "1.5.0"`).

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/Proof-of-Human-Network/sdk-ios", from: "1.5.0"),
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

// Local miner routing — write operations (any non-GET request except
// POST /gossip) must go to a node you control. Pass localBaseURL to route
// them to your local miner while reads still use the public nodes; without
// it, writes to a non-loopback node fail with a 403 POHError.httpError.
let poh = POHClient(nodes: pohDefaultNodes, localBaseURL: URL(string: "http://127.0.0.1:3456")!)

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

// Or in one call — uses kp.address and builds the proof itself
try await poh.registerKeyPair(kp)

// The address a keypair maps to (from its SPKI PEM public key)
let addr = POHSigning.deriveAddressFromSigningKey(kp.signingPublicKey)
```

**Rotating a key** — replacing an already-registered key requires a rotation
proof signed with the *old* private key:

```swift
let proof = try POHSigning.createRotationProof(
    address: "pohAbc123...",
    newSigningPublicKey: newKp.signingPublicKey,
    existingPrivateKeyPem: oldPrivateKeyPem
)
try await poh.registerKeyPair(newKp, rotationProof: proof)
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

`transfer()` fetches the nonce, builds, signs, and submits in one call. It is
pending-aware: when the account has transactions waiting in the mempool it uses
`pendingNonce + 1` (falling back to `nonce + 1`), so back-to-back transfers
don't collide.

### Low-level hash and sign

```swift
// Compute a canonical SHA-256 tx hash
let hash = POHSigning.computeTxHash(
    from: "pohAbc...", to: "pohDef...", amount: 5_000_000_000,
    fee: 0, nonce: 42, timestamp: 1_700_000_000_000, memo: ""
)

// Sign an arbitrary UTF-8 message
let sig = try POHSigning.signData("hello", privateKeyPem: kp.signingPrivateKey)

// Client-side job id ("job-<millis>-<8 hex>") — fee-required jobs must fix the
// id before signing, since the payment proof is bound to it
let jobId = POHSigning.generateJobId()
```

---

## Chat Encryption (POHChatCrypto)

End-to-end encryption for chat payloads (X25519 + HKDF + AES-256-GCM),
compatible with the node's envelope format.

```swift
// Deterministic X25519 keypair from a stable secret (Data or String)
let ekp = try POHChatCrypto.deriveEncryptionKeypair(stableSecret)

// Encrypt for a recipient (plaintext as String or Data)
let env = try POHChatCrypto.seal(recipientPubB64: their.publicKeyB64, plaintext: "hello")

// Decrypt an envelope
let plaintext = try POHChatCrypto.open(env, privateScalarB64: ekp.privateKeyB64)
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
| `POHClient(baseURL:localBaseURL:apiKey:walletAddress:timeout:)` | Single-node client |
| `POHClient(nodes:localBaseURL:apiKey:walletAddress:timeout:)` | Multi-node — picks fastest live node |

`localBaseURL` (optional, both inits): local miner URL that write operations
(any non-GET request except `POST /gossip`) are routed to; reads keep using
the public nodes. Without it, writes to a non-loopback node throw a 403
`POHError.httpError`.

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
| `registerSigningKey(_:publicKeyPem:proof:rotationProof:)` | `[String: JSONValue]` | Register Ed25519 public key |
| `registerKeyPair(_:rotationProof:)` | `[String: JSONValue]` | Register a `POHKeyPair` — builds the proof itself |
| `transfer(from:to:amountPOH:keyPair:fee:memo:)` | `TxSubmitResult` | Build, sign, submit in one call (pending-nonce aware) |

### Signing (POHSigning)

| Method | Returns | Description |
|--------|---------|-------------|
| `generateKeyPair()` | `POHKeyPair` | Fresh Ed25519 keypair |
| `deriveAddressFromSigningKey(_:)` | `String` | `poh…` address from an SPKI PEM public key |
| `signData(_:privateKeyPem:)` | `String` | Base64 Ed25519 signature |
| `createSigningProof(walletAddress:privateKeyPem:)` | `String` | Proof for key registration |
| `createRotationProof(address:newSigningPublicKey:existingPrivateKeyPem:)` | `String` | Proof (signed with the old key) to replace a registered key |
| `computeTxHash(from:to:amount:fee:nonce:timestamp:memo:)` | `String` | SHA-256 canonical tx hash |
| `buildTransfer(from:to:amountPOH:nonce:fee:memo:)` | `PohTx` | Build unsigned transfer |
| `signTransaction(_:keyPair:)` | `PohTx` | Sign with a `POHKeyPair` |
| `signTransaction(_:privateKeyPem:publicKeyPem:)` | `PohTx` | Sign with raw PEM strings |
| `generateJobId()` | `String` | Client-side job id (`job-<millis>-<8 hex>`) |
| `computeJobPaymentHash(jobId:requesterAddress:minerAddress:amount:nonce:)` | `String` | Canonical hash for a job fee payment (used internally by `submitJob`/`runCompute`) |
| `signJobPayment(jobId:requesterAddress:minerAddress:amount:nonce:privateKeyPem:)` | `(txHash: String, signature: String)` | Sign a job fee payment proof (used internally) |

### Chat Encryption (POHChatCrypto)

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

The chain now carries five regional stablecoins alongside POH: `aiGEL`,
`aiKGS`, `aiAMD`, `aiETB`, `aiBTN` (displayed αιGEL …). They use **2 decimals**
(1 unit = 100 raw); POH keeps 9 (1 POH = 1e9 μPOH).

Wire protocol (implement when adding native support to this SDK):

- `PohTransaction` gains an optional `currency` field. **Hash preimage rule:**
  `currency` is appended after `memo` in the signed JSON payload ONLY when
  non-POH — a POH transaction hashes byte-identically to the historical shape
  and must NOT carry the key at all.
- Job payment hash: `currency` is the SIXTH key of
  `{jobId,requesterAddress,minerAddress,amount,nonce,currency}` ONLY when
  non-POH.
- `GET /api/assets` lists the registry (tickers, decimals, display names, gas
  prices). `GET /api/wallet/balance` adds `assets: { ticker: {raw, display} }`.
- Job payloads accept `currency`; the miner receives exactly the currency paid.

Native Swift/Kotlin bindings for these fields are NOT yet implemented in this
SDK — see sdk-js (reference implementation) for exact semantics.
