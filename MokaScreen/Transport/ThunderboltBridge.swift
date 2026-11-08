// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation
import SystemConfiguration

/// The state of the Thunderbolt Bridge network interface.
struct BridgeState: Equatable {
	/// BSD name, typically `bridge0`.
	var name: String
	/// Kernel interface index, for scoping sockets and Bonjour to the bridge.
	var index: UInt32
	/// True when a Thunderbolt cable to another Mac is carrying link.
	var isLinkUp: Bool
	/// The bridge's IPv4 and IPv6 addresses, numeric.
	var addresses: [String]

	/// The bridge is up and usable.
	var isUsable: Bool { isLinkUp && index != 0 }

	/// Whether `other` needs sockets and Bonjour restarted; an address appearing does not.
	func needsRestart(from other: BridgeState?) -> Bool {
		guard let other else { return true }
		return name != other.name || index != other.index || isUsable != other.isUsable
	}
}

/// Locates the Thunderbolt Bridge and reports changes to its link state.
///
/// Polled rather than notification-driven: a 1 s `ioctl` costs nothing, catches every
/// transition (cable, sleep/wake, the user toggling the service), and has no
/// subscription state that can be lost across sleep.
@MainActor
final class BridgeMonitor {
	private var timer: Timer?
	private(set) var state: BridgeState?
	private let onChange: (BridgeState?) -> Void

	/// Starts monitoring. `onChange` runs on the main actor, once immediately and then on every change.
	init(onChange: @escaping (BridgeState?) -> Void) {
		self.onChange = onChange
		poll(force: true)
		timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.poll(force: false) }
		}
	}

	/// Stops monitoring.
	func stop() {
		timer?.invalidate()
		timer = nil
	}

	private func poll(force: Bool) {
		let current = Self.currentState()
		if force || current != state {
			state = current
			onChange(current)
		}
	}

	/// Reads the bridge's state now.
	nonisolated static func currentState() -> BridgeState? {
		let name = bridgeName()
		let index = if_nametoindex(name)
		guard index != 0 else { return nil }
		return BridgeState(name: name, index: index, isLinkUp: isLinkActive(name), addresses: addresses(of: name))
	}

	/// The BSD name of the enabled bridge service, which is where macOS puts the Thunderbolt Bridge.
	///
	/// Bridges created on the fly (Internet Sharing's `bridge100`, for one) have no network
	/// service, so asking SystemConfiguration for *configured* bridges skips them without relying
	/// on localized names like "Thunderbolt Bridge". "Bridge" is the interface-type identifier
	/// (the value of the non-public `kSCNetworkInterfaceTypeBridge`), not a display string.
	nonisolated private static func bridgeName() -> String {
		if let prefs = SCPreferencesCreate(nil, "MokaScreen" as CFString, nil),
		   let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] {
			for service in services where SCNetworkServiceGetEnabled(service) {
				if let interface = SCNetworkServiceGetInterface(service),
				   SCNetworkInterfaceGetInterfaceType(interface) as String? == "Bridge",
				   let name = SCNetworkInterfaceGetBSDName(interface) as String? {
					return name
				}
			}
		}
		return "bridge0"
	}

	/// Link state as `ifconfig` reports it ("status: active"). `IFF_RUNNING` is not enough: the
	/// bridge stays RUNNING with no cable attached.
	nonisolated private static func isLinkActive(_ name: String) -> Bool {
		let fd = socket(AF_INET, SOCK_DGRAM, 0)
		guard fd >= 0 else { return false }
		defer { close(fd) }
		var request = ifmediareq()
		withUnsafeMutableBytes(of: &request.ifm_name) { raw in
			let bytes = Array(name.utf8.prefix(raw.count - 1))
			raw.copyBytes(from: bytes)
		}
		guard ioctl(fd, siocgifmedia, &request) == 0 else { return false }
		let valid = request.ifm_status & IFM_AVALID != 0
		let active = request.ifm_status & IFM_ACTIVE != 0
		return valid && active
	}

	/// `SIOCGIFMEDIA`, which Swift does not import because it is a function-like macro:
	/// `_IOWR('i', 56, struct ifmediareq)`.
	nonisolated private static let siocgifmedia: UInt = {
		let iocInOut: UInt = 0xC000_0000
		let length = UInt(MemoryLayout<ifmediareq>.size) & 0x1FFF
		return iocInOut | (length << 16) | (UInt(UInt8(ascii: "i")) << 8) | 56
	}()

	nonisolated private static func addresses(of name: String) -> [String] {
		var list: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&list) == 0, let first = list else { return [] }
		defer { freeifaddrs(first) }
		var result: [String] = []
		for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
			guard String(cString: entry.pointee.ifa_name) == name,
			      let sa = entry.pointee.ifa_addr,
			      let address = SocketAddress(sa)
			else { continue }
			result.append(address.host)
		}
		return result.sorted { $0.contains(":") == $1.contains(":") ? $0 < $1 : !$0.contains(":") }
	}
}
