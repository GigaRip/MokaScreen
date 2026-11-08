// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import CoreMedia

/// The host clock, in nanoseconds. ScreenCaptureKit timestamps, `CACurrentMediaTime`, and
/// `CAMetalDrawable.presentedTime` all count on this same clock.
enum HostClock {
	static var now: UInt64 {
		UInt64(max(0, CMClockGetTime(CMClockGetHostTimeClock()).seconds) * 1e9)
	}
}
