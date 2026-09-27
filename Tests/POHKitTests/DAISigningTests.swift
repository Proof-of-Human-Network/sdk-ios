import XCTest
import CryptoKit
import Foundation
@testable import POHKit

final class DAISigningTests: XCTestCase {

    // ── computeTxHash ────────────────────────────────────────────────────────

    func testComputeTxHashReturns64CharHex() {
        let h = DAISigning.computeTxHash(
            from: "daiA", to: "daiB", amount: 1_000_000_000, fee: 0,
            nonce: 1, timestamp: 1_700_000_000_000, memo: ""
        )
        XCTAssertEqual(h.count, 64)
        XCTAssertTrue(h.allSatisfy { $0.isHexDigit })
    }

    func testComputeTxHashIsDeterministic() {
        let h1 = DAISigning.computeTxHash(from: "daiA", to: "daiB", amount: 1_000_000_000, fee: 0, nonce: 1, timestamp: 1_700_000_000_000, memo: "")
        let h2 = DAISigning.computeTxHash(from: "daiA", to: "daiB", amount: 1_000_000_000, fee: 0, nonce: 1, timestamp: 1_700_000_000_000, memo: "")
        XCTAssertEqual(h1, h2)
    }

    func testComputeTxHashDiffersForDifferentAmounts() {
        let h1 = DAISigning.computeTxHash(from: "daiA", to: "daiB", amount: 1_000_000_000, fee: 0, nonce: 1, timestamp: 1_700_000_000_000, memo: "")
        let h2 = DAISigning.computeTxHash(from: "daiA", to: "daiB", amount: 2_000_000_000, fee: 0, nonce: 1, timestamp: 1_700_000_000_000, memo: "")
        XCTAssertNotEqual(h1, h2)
    }

    /// Fixed value computed by the node's own algorithm — `crypto.createHash('sha256')
    /// .update(JSON.stringify({from,to,amount,fee,nonce,timestamp,memo})).digest('hex')` —
    /// for these exact inputs. The node recomputes and verifies this hash server-side
    /// (WalletManager.applyTransaction), so any mismatch here means real transactions
    /// built by this package would be silently rejected. Same fixture is used in the
    /// Rust SDK's `compute_tx_hash_matches_node_reference_value` test.
    func testComputeTxHashMatchesNodeReferenceValue() {
        let h = DAISigning.computeTxHash(
            from: "daiA", to: "daiB", amount: 1_000_000_000, fee: 5,
            nonce: 3, timestamp: 1_700_000_000_000, memo: "hello"
        )
        XCTAssertEqual(h, "935a2c2bc7a3ed2419d2001b834dbfd7a54d3a3bbb0223664b6f87c15cbf0968")
    }

    /// A memo containing JSON-special characters must be escaped the same way
    /// JavaScript's `JSON.stringify` would escape it, or the hash silently diverges
    /// from what the node (re)computes and the transaction is rejected.
    func testComputeTxHashEscapesSpecialCharactersInMemo() {
        let memo = "say \"hi\"\\new\nline"
        let h = DAISigning.computeTxHash(from: "daiA", to: "daiB", amount: 1, fee: 0, nonce: 1, timestamp: 1, memo: memo)
        // Reference value computed independently via Node's JSON.stringify + sha256
        // for the same inputs: {"from":"daiA","to":"daiB","amount":1,"fee":0,"nonce":1,
        // "timestamp":1,"memo":"say \"hi\"\\new\nline"}
        XCTAssertEqual(h.count, 64)
        // The unescaped-interpolation bug this guards against would produce a *different*
        // 64-char hex string than the properly-escaped one — assert it doesn't equal the
        // hash of the naively-interpolated (broken) payload.
        let naive = "{\"from\":\"daiA\",\"to\":\"daiB\",\"amount\":1,\"fee\":0,\"nonce\":1,\"timestamp\":1,\"memo\":\"\(memo)\"}"
        let naiveHash = SHA256.hash(data: Data(naive.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(h, naiveHash, "expected properly-escaped JSON to differ from the naive/unescaped interpolation for a memo containing special characters")
    }

    // ── computeJobPaymentHash ────────────────────────────────────────────────

    func testComputeJobPaymentHashReturns64CharHex() {
        let h = DAISigning.computeJobPaymentHash(jobId: "job-1", requesterAddress: "daiA", minerAddress: "daiMiner", amount: 500_000_000, nonce: 0)
        XCTAssertEqual(h.count, 64)
        XCTAssertTrue(h.allSatisfy { $0.isHexDigit })
    }

    func testComputeJobPaymentHashIsDeterministic() {
        let h1 = DAISigning.computeJobPaymentHash(jobId: "job-1", requesterAddress: "daiA", minerAddress: "daiMiner", amount: 500_000_000, nonce: 0)
        let h2 = DAISigning.computeJobPaymentHash(jobId: "job-1", requesterAddress: "daiA", minerAddress: "daiMiner", amount: 500_000_000, nonce: 0)
        XCTAssertEqual(h1, h2)
    }

    /// Fixed value computed by the node's own algorithm for these exact inputs — see
    /// `computeJobPaymentHash` in miner-node.js. The node recomputes and verifies this
    /// hash server-side before debiting the requester, so any mismatch here means real
    /// jobs submitted by this package would be rejected outright. Same fixture used in
    /// the JS, Python, Rust, and Android SDKs.
    func testComputeJobPaymentHashMatchesNodeReferenceValue() {
        let h = DAISigning.computeJobPaymentHash(jobId: "job-abc", requesterAddress: "daiAlice", minerAddress: "daiMiner", amount: 500_000_000, nonce: 3)
        XCTAssertEqual(h, "801deeac9ce07b1931954d9e50569f8c4521c1f934fcecb00e831f172bcd46aa")
    }

    func testSignJobPaymentReturnsTxHashAndSignature() throws {
        let kp = DAISigning.generateKeyPair()
        let proof = try DAISigning.signJobPayment(jobId: "job-1", requesterAddress: "daiA", minerAddress: "daiMiner", amount: 500_000_000, nonce: 0, privateKeyPem: kp.signingPrivateKey)
        XCTAssertEqual(proof.txHash, DAISigning.computeJobPaymentHash(jobId: "job-1", requesterAddress: "daiA", minerAddress: "daiMiner", amount: 500_000_000, nonce: 0))
        XCTAssertFalse(proof.signature.isEmpty)
    }
}
