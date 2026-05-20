# proofofhuman

Swift Package Manager SDK for [Proof of Human](https://proofofhuman.ge).  
Supports **iOS 15+**, **macOS 12+**, **tvOS 15+**, **watchOS 8+**.  
Zero dependencies — built on `URLSession` and Swift Concurrency.

## Installation

In Xcode: **File → Add Package Dependencies** → paste the repo URL.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Proof-of-Human-Network/sdk-ios", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: ["proofofhuman"]),
]
```

## Quick start

```swift
import proofofhuman

let poh = POHClient(
    baseURL: URL(string: "https://proofofhuman.ge")!,
    apiKey:  "your-api-key"   // or use walletAddress: for free tier
)

// Single scan
let result = try await poh.scan("0xabc...")
// result.result: true = human, false = not human, nil = inconclusive

// AI brain verdict
if let key = result.brainKey {
    let verdict = try await poh.getBrainVerdict(brainKey: key)
    print(verdict.reasoning ?? "")
}
```

## Bulk scans with job polling

```swift
// Submit — returns immediately with a job ID
let job = try await poh.scanBulk(["0xaaa...", "0xbbb...", "0xccc..."])

// Option A — poll until done
let final = try await poh.pollJob(job.jobId, options: .init(
    interval:   2,              // check every 2 s
    onProgress: { print("\($0.percent)%") }
))
print(final.results)

// Option B — stream progress
for try await snap in poh.watchJob(job.jobId) {
    print("\(snap.percent)% (\(snap.done)/\(snap.total))")
}

// Option C — one-liner convenience
let done = try await poh.scanAndWait(["0xaaa...", "0xbbb..."])
```

## Signal methods

```swift
// All methods, sorted by vote score
let methods = try await poh.getMethods()

// Single method
let method = try await poh.getMethod("methodId")
```

## API reference

### `POHClient(baseURL:apiKey:walletAddress:timeout:)`

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `baseURL` | `URL` | **required** | Base URL of the POH API |
| `apiKey` | `String?` | `nil` | API key (paid tier) |
| `walletAddress` | `String?` | `nil` | Solana wallet for free-tier tracking |
| `timeout` | `TimeInterval` | `30` | Per-request timeout in seconds |

### Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `scan(_:options:)` | `ScanResult` | Single-address synchronous scan |
| `scanBulk(_:options:)` | `BulkScanResult` | Submit bulk scan job |
| `getJob(_:)` | `JobStatus` | Fetch current job snapshot |
| `pollJob(_:options:)` | `JobStatus` | Poll until done/error |
| `watchJob(_:options:)` | `AsyncThrowingStream<JobStatus>` | Stream poll updates |
| `scanAndWait(_:scanOptions:pollOptions:)` | `JobStatus` | Bulk + poll in one call |
| `getBrainVerdict(brainKey:)` | `BrainVerdict` | AI verdict for a scan |
| `getMethods(walletAddress:)` | `[Method]` | List signal methods |
| `getMethod(_:)` | `Method` | Single method by ID |

## Error handling

```swift
do {
    let result = try await poh.scan("0xabc...")
} catch let err as POHError {
    switch err {
    case .httpError(let code, let msg): print("API error \(code): \(msg)")
    case .requestTimeout:               print("Timed out")
    case .jobTimedOut(let id, _):       print("Job \(id) took too long")
    default:                            print(err.localizedDescription)
    }
}
```

## License

MIT
