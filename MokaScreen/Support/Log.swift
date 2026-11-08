// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import os

/// Unified-logging categories. Stream with `log stream --predicate 'subsystem == "com.gigarip.mokascreen"'`.
enum Log {
	private static let subsystem = "com.gigarip.mokascreen"
	static let app = Logger(subsystem: subsystem, category: "app")
	static let display = Logger(subsystem: subsystem, category: "display")
	static let capture = Logger(subsystem: subsystem, category: "capture")
	static let transport = Logger(subsystem: subsystem, category: "transport")
	static let render = Logger(subsystem: subsystem, category: "render")
}
