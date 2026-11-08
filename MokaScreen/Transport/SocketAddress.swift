// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation

/// An IPv4 or IPv6 socket address, including the scope of a link-local IPv6 address.
struct SocketAddress: Hashable, CustomStringConvertible {
	private(set) var storage = sockaddr_storage()

	/// Copies a `sockaddr_in` or `sockaddr_in6`. Returns `nil` for other families.
	init?(_ address: UnsafePointer<sockaddr>) {
		let length: Int
		switch Int32(address.pointee.sa_family) {
		case AF_INET: length = MemoryLayout<sockaddr_in>.size
		case AF_INET6: length = MemoryLayout<sockaddr_in6>.size
		default: return nil
		}
		withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: UnsafeRawBufferPointer(start: address, count: length)) }
	}

	/// Resolves a numeric or named host. A link-local IPv6 literal may carry a zone (`fe80::1%bridge0`).
	static func resolve(host: String, port: UInt16) throws -> [SocketAddress] {
		var hints = addrinfo()
		hints.ai_socktype = SOCK_STREAM
		hints.ai_protocol = IPPROTO_TCP
		var result: UnsafeMutablePointer<addrinfo>?
		guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
			throw TransportError.unresolvable(host)
		}
		defer { freeaddrinfo(first) }
		var addresses: [SocketAddress] = []
		for info in sequence(first: first, next: { $0.pointee.ai_next }) {
			if let sa = info.pointee.ai_addr, let address = SocketAddress(sa) {
				addresses.append(address)
			}
		}
		return addresses
	}

	var family: Int32 {
		Int32(storage.ss_family)
	}

	var length: socklen_t {
		socklen_t(family == AF_INET6 ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
	}

	var port: UInt16 {
		get {
			withSockaddr { sa in
				family == AF_INET6
					? UInt16(bigEndian: sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_port })
					: UInt16(bigEndian: sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port })
			}
		}
		set {
			let family = family
			withUnsafeMutableBytes(of: &storage) { raw in
				if family == AF_INET6 {
					raw.storeBytes(of: newValue.bigEndian, toByteOffset: MemoryLayout<sockaddr_in6>.offset(of: \.sin6_port)!, as: UInt16.self)
				} else {
					raw.storeBytes(of: newValue.bigEndian, toByteOffset: MemoryLayout<sockaddr_in>.offset(of: \.sin_port)!, as: UInt16.self)
				}
			}
		}
	}

	/// True for `fe80::/10`.
	var isIPv6LinkLocal: Bool {
		guard family == AF_INET6 else { return false }
		return withSockaddr { sa in
			sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
				let bytes = $0.pointee.sin6_addr.__u6_addr.__u6_addr8
				return bytes.0 == 0xFE && (bytes.1 & 0xC0) == 0x80
			}
		}
	}

	/// The interface index of a scoped IPv6 address; zero when unscoped or IPv4.
	var scopeID: UInt32 {
		get {
			guard family == AF_INET6 else { return 0 }
			return withSockaddr { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_scope_id } }
		}
		set {
			guard family == AF_INET6 else { return }
			withUnsafeMutableBytes(of: &storage) { raw in
				raw.storeBytes(of: newValue, toByteOffset: MemoryLayout<sockaddr_in6>.offset(of: \.sin6_scope_id)!, as: UInt32.self)
			}
		}
	}

	func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>) throws -> T) rethrows -> T {
		try withUnsafeBytes(of: storage) { raw in
			try body(raw.baseAddress!.assumingMemoryBound(to: sockaddr.self))
		}
	}

	/// The numeric host, with the zone for scoped IPv6 addresses.
	var host: String {
		var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
		let result = withSockaddr { getnameinfo($0, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) }
		return result == 0 ? String(cString: buffer) : "?"
	}

	var description: String {
		family == AF_INET6 ? "[\(host)]:\(port)" : "\(host):\(port)"
	}

	static func == (lhs: SocketAddress, rhs: SocketAddress) -> Bool {
		lhs.description == rhs.description
	}

	func hash(into hasher: inout Hasher) {
		hasher.combine(description)
	}
}
