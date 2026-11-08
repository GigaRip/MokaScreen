// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import AppKit
import Testing
@testable import MokaScreen

@MainActor
struct RoleTests {
	@Test(arguments: [Role.sender, .receiver])
	func symbolExists(role: Role) {
		#expect(NSImage(systemSymbolName: role.symbolName, accessibilityDescription: nil) != nil, "\(role.symbolName)")
	}
}
