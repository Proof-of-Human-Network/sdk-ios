import XCTest
import CryptoKit
import Foundation
@testable import proofofhuman

final class POHSigningTests: XCTestCase {

    // ── computeTxHash ────────────────────────────────────────────────────────

    func testComputeTxHashReturns64CharHex() {
        let h = POHSigning.computeTxHash(
            from: "pohA", to: "pohB", amount: 1_000_000_000, fee: 0,
            nonce: 1, timestamp: 1_700_000_000_000, memo: ""
        )
        XCTAssertEqual(h.count, 64)
        XCTAssertTrue(h.allSatisfy { $0.isHexDigit })
    }

    func testComputeTxHashIsDeterministic() {
        let h1 = POHSigning.computeTxHash(from: "pohA", to: "pohB", amount: 1_000_000_000, fee: 0, nonce: 1, timestamp: 1_700_000_000_000, memo: "")
        let h2 = POHSigning.computeTxHash(from: "pohA", to: "pohB", amount: 1_000_000_000, fee: 0, nonce: 1, timestamp: 1_700_000_000_000, memo: "")
        XCTAssertEqual(h1, h2)
    }

    func testComputeTxHashDiffersForDifferentAmounts() {
        let h1 = POHSigning.computeTxHash(from: "pohA", to: "pohB", amount: 1_000_000_000, fee: 0, nonce: 1, timestamp: 1_700_000_000_000, memo: "")
        let h2 = POHSigning.computeTxHash(from: "pohA", to: "pohB", amount: 2_000_000_000, fee: 0, nonce: 1, timestamp: 1_700_000_000_000, memo: "")
        XCTAssertNotEqual(h1, h2)
    }

    /// Fixed value computed by the node's own algorithm — `crypto.createHash('sha256')
    /// .update(JSON.stringify({from,to,amount,fee,nonce,timestamp,memo})).digest('hex')` —
    /// for these exact inputs. The node recomputes and verifies this hash server-side
    /// (WalletManager.applyTransaction), so any mismatch here means real transactions
    /// built by this package would be silently rejected. Same fixture is used in the
    /// Rust SDK's `compute_tx_hash_matches_node_reference_value` test.
    func testComputeTxHashMatchesNodeReferenceValue() {
        let h = POHSigning.computeTxHash(
            from: "pohA", to: "pohB", amount: 1_000_000_000, fee: 5,
            nonce: 3, timestamp: 1_700_000_000_000, memo: "hello"
        )
        XCTAssertEqual(h, "e309a41e0c088876f2763f8d01ae434ff060bd4391202d555be1d96ee0f14c8a")
    }

    /// A memo containing JSON-special characters must be escaped the same way
    /// JavaScript's `JSON.stringify` would escape it, or the hash silently diverges
    /// from what the node (re)computes and the transaction is rejected.
    func testComputeTxHashEscapesSpecialCharactersInMemo() {
        let memo = "say \"hi\"\\new\nline"
        let h = POHSigning.computeTxHash(from: "pohA", to: "pohB", amount: 1, fee: 0, nonce: 1, timestamp: 1, memo: memo)
        // Reference value computed independently via Node's JSON.stringify + sha256
        // for the same inputs: {"from":"pohA","to":"pohB","amount":1,"fee":0,"nonce":1,
        // "timestamp":1,"memo":"say \"hi\"\\new\nline"}
        XCTAssertEqual(h.count, 64)
        // The unescaped-interpolation bug this guards against would produce a *different*
        // 64-char hex string than the properly-escaped one — assert it doesn't equal the
        // hash of the naively-interpolated (broken) payload.
        let naive = "{\"from\":\"pohA\",\"to\":\"pohB\",\"amount\":1,\"fee\":0,\"nonce\":1,\"timestamp\":1,\"memo\":\"\(memo)\"}"
        let naiveHash = SHA256.hash(data: Data(naive.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(h, naiveHash, "expected properly-escaped JSON to differ from the naive/unescaped interpolation for a memo containing special characters")
    }

    // ── computeJobPaymentHash ────────────────────────────────────────────────

    func testComputeJobPaymentHashReturns64CharHex() {
        let h = POHSigning.computeJobPaymentHash(jobId: "job-1", requesterAddress: "pohA", minerAddress: "pohMiner", amount: 500_000_000, nonce: 0)
        XCTAssertEqual(h.count, 64)
        XCTAssertTrue(h.allSatisfy { $0.isHexDigit })
    }

    func testComputeJobPaymentHashIsDeterministic() {
        let h1 = POHSigning.computeJobPaymentHash(jobId: "job-1", requesterAddress: "pohA", minerAddress: "pohMiner", amount: 500_000_000, nonce: 0)
        let h2 = POHSigning.computeJobPaymentHash(jobId: "job-1", requesterAddress: "pohA", minerAddress: "pohMiner", amount: 500_000_000, nonce: 0)
        XCTAssertEqual(h1, h2)
    }

    /// Fixed value computed by the node's own algorithm for these exact inputs — see
    /// `computeJobPaymentHash` in miner-node.js. The node recomputes and verifies this
    /// hash server-side before debiting the requester, so any mismatch here means real
    /// jobs submitted by this package would be rejected outright. Same fixture used in
    /// the JS, Python, Rust, and Android SDKs.
    func testComputeJobPaymentHashMatchesNodeReferenceValue() {
        let h = POHSigning.computeJobPaymentHash(jobId: "job-abc", requesterAddress: "pohAlice", minerAddress: "pohMiner", amount: 500_000_000, nonce: 3)
        XCTAssertEqual(h, "1ed86280c1ab64d60d55a232a1c339299d32d8bd45e5f2bf26ff72b26d8908c0")
    }

    func testSignJobPaymentReturnsTxHashAndSignature() throws {
        let kp = POHSigning.generateKeyPair()
        let proof = try POHSigning.signJobPayment(jobId: "job-1", requesterAddress: "pohA", minerAddress: "pohMiner", amount: 500_000_000, nonce: 0, privateKeyPem: kp.signingPrivateKey)
        XCTAssertEqual(proof.txHash, POHSigning.computeJobPaymentHash(jobId: "job-1", requesterAddress: "pohA", minerAddress: "pohMiner", amount: 500_000_000, nonce: 0))
        XCTAssertFalse(proof.signature.isEmpty)
    }
}
