import XCTest
@testable import NexaWalLogic

final class NetworkRoutingTests: XCTestCase {
    private let clearnet = "http://127.0.0.1:18092"
    private let i2p = "cvxtgqjorfif6i5x5fenys6fj7hzddbgavpyutps6gphywnlklqa.b32.i2p:18081"

    func testScanUsesClearnetForClearnetAndHybrid() {
        XCTAssertEqual(NetworkRouting.scanNodeURL(policy: .clearnet, clearnetNodeURL: clearnet, i2pRPCAddress: i2p), clearnet)
        XCTAssertEqual(NetworkRouting.scanNodeURL(policy: .hybrid, clearnetNodeURL: clearnet, i2pRPCAddress: i2p), clearnet)
    }

    func testScanUsesI2POnlyForI2PPolicy() {
        XCTAssertEqual(
            NetworkRouting.scanNodeURL(policy: .i2p, clearnetNodeURL: clearnet, i2pRPCAddress: i2p),
            NetworkRouting.normalizeURL(i2p)
        )
    }

    func testBroadcastUsesI2PForI2PAndHybrid() {
        let expected = NetworkRouting.normalizeURL(i2p)
        XCTAssertEqual(NetworkRouting.broadcastNodeURL(policy: .i2p, clearnetNodeURL: clearnet, i2pRPCAddress: i2p), expected)
        XCTAssertEqual(NetworkRouting.broadcastNodeURL(policy: .hybrid, clearnetNodeURL: clearnet, i2pRPCAddress: i2p), expected)
        XCTAssertEqual(NetworkRouting.broadcastNodeURL(policy: .clearnet, clearnetNodeURL: clearnet, i2pRPCAddress: i2p), clearnet)
    }

    func testProxyRequiredAndPolicyAware() {
        XCTAssertFalse(NetworkRouting.shouldUseI2PHTTPProxy(policy: .i2p, proxyConfigured: false, forBroadcast: true))
        XCTAssertFalse(NetworkRouting.shouldUseI2PHTTPProxy(policy: .clearnet, proxyConfigured: true, forBroadcast: true))
        XCTAssertTrue(NetworkRouting.shouldUseI2PHTTPProxy(policy: .i2p, proxyConfigured: true, forBroadcast: false))
        XCTAssertTrue(NetworkRouting.shouldUseI2PHTTPProxy(policy: .hybrid, proxyConfigured: true, forBroadcast: true))
        XCTAssertFalse(NetworkRouting.shouldUseI2PHTTPProxy(policy: .hybrid, proxyConfigured: true, forBroadcast: false))
    }
}

final class SendSafetyTests: XCTestCase {
    func testUnlockedPrecheck() {
        XCTAssertTrue(SendSafety.hasUnlockedForExactSend(amountPiconero: 1_000, feePiconero: 100, unlockedPiconero: 1_100))
        XCTAssertFalse(SendSafety.hasUnlockedForExactSend(amountPiconero: 1_000, feePiconero: 100, unlockedPiconero: 1_099))
        XCTAssertFalse(SendSafety.hasUnlockedForExactSend(amountPiconero: UInt64.max, feePiconero: 1, unlockedPiconero: UInt64.max))
    }

    func testSiblingRetryOnlyPreBroadcastFeeRate() {
        let cuprate = "http://127.0.0.1:18092"
        XCTAssertEqual(
            SendSafety.shouldRetryViaSiblingMonerod(errorText: "fee_rate failed", coreMessage: "", endpoint: cuprate),
            "http://127.0.0.1:18081"
        )
        XCTAssertNil(
            SendSafety.shouldRetryViaSiblingMonerod(
                errorText: "fee_rate failed",
                coreMessage: "key image already spent",
                endpoint: cuprate
            )
        )
        XCTAssertNil(
            SendSafety.shouldRetryViaSiblingMonerod(errorText: "fee_rate failed", coreMessage: "", endpoint: "http://127.0.0.1:18081")
        )
    }
}

final class SendGateTests: XCTestCase {
    func testSecondConcurrentLockFailsFast() throws {
        let gate = SendGate()
        XCTAssertTrue(gate.tryBegin())
        XCTAssertThrowsError(try gate.withLock { XCTFail("second lock should not run") }) { error in
            XCTAssertEqual(error as? SendGate.Error, .alreadyInProgress)
        }
        gate.end()
        try gate.withLock { }
    }
}
