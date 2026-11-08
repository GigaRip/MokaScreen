// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Testing
@testable import MokaScreen

@MainActor
struct BridgeStateTests {
	@Test func appModelReportsTheBridgeWithoutStartingASession() {
		let model = AppModel()
		#expect(model.bridge == BridgeMonitor.currentState())
		#expect(model.sender.status == .stopped)
		#expect(model.receiver.status == .stopped)
	}

	@Test func stoppedSessionsIgnoreBridgeChanges() {
		let sender = SenderSession()
		let receiver = ReceiverSession()
		let up = BridgeState(name: "bridge0", index: 13, isLinkUp: true, addresses: [])
		sender.bridgeChanged(up)
		receiver.bridgeChanged(up)
		sender.bridgeChanged(nil)
		receiver.bridgeChanged(nil)
		#expect(sender.status == .stopped)
		#expect(receiver.status == .stopped)
	}

	@Test func onlyLinkChangesRestartDiscovery() {
		let down = BridgeState(name: "bridge0", index: 13, isLinkUp: false, addresses: [])
		var up = down
		up.isLinkUp = true
		var addressed = up
		addressed.addresses = ["169.254.1.2"]
		#expect(up.needsRestart(from: down))
		#expect(up.needsRestart(from: nil))
		#expect(!addressed.needsRestart(from: up))
	}
}
