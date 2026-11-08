// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation
import os

/// Accepts TCP connections on one port, on IPv4 and IPv6, from one place only.
final class TCPListener {
	/// Where connections may come from.
	enum Scope: Equatable {
		/// Only through this network interface (the Thunderbolt Bridge).
		case interface(UInt32)
		/// Only from this Mac; used by the loopback self-test.
		case loopback
	}

	private let sockets: [Int32]
	private let wakePipe: (read: Int32, write: Int32)
	private let thread: Thread

	/// Starts listening and calls `onAccept` on a private thread for each connection.
	/// - Throws: ``TransportError`` if the port cannot be bound (for example, another copy of MokaScreen holds it).
	init(port: UInt16, scope: Scope, onAccept: @escaping (TCPStream) -> Void) throws {
		var fds: [Int32] = []
		do {
			fds.append(try Self.makeSocket(family: AF_INET, port: port, scope: scope))
			fds.append(try Self.makeSocket(family: AF_INET6, port: port, scope: scope))
		} catch {
			fds.forEach { Darwin.close($0) }
			throw error
		}
		var pipeFDs: [Int32] = [0, 0]
		guard pipe(&pipeFDs) == 0 else {
			fds.forEach { Darwin.close($0) }
			throw TransportError.errno("pipe")
		}
		sockets = fds
		wakePipe = (pipeFDs[0], pipeFDs[1])

		let wake = wakePipe.read
		thread = Thread {
			Self.acceptLoop(sockets: fds, wake: wake, onAccept: onAccept)
		}
		thread.name = "MokaScreen.accept"
		thread.qualityOfService = .userInitiated
		thread.start()
	}

	/// Stops accepting. Connections already handed out are unaffected.
	func stop() {
		var byte: UInt8 = 1
		_ = Darwin.write(wakePipe.write, &byte, 1)
	}

	deinit {
		stop()
		Darwin.close(wakePipe.write)
	}

	private static func makeSocket(family: Int32, port: UInt16, scope: Scope) throws -> Int32 {
		let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
		guard fd >= 0 else { throw TransportError.errno("socket") }
		var ok = false
		defer { if !ok { Darwin.close(fd) } }

		var one: Int32 = 1
		setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
		if family == AF_INET6 {
			setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
		}
		// Set before listen() so accepted sockets inherit it and the window opens at full size.
		var buffer: Int32 = 4 << 20
		setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))

		if case .interface(let index) = scope {
			// Scoping the listener to the bridge keeps the receiver unreachable over Wi-Fi: only a
			// Mac on the other end of the Thunderbolt cable can put pixels on this screen.
			try TCPStream.bind(fd, toInterface: index, family: family)
		}

		let result: Int32
		if family == AF_INET6 {
			var address = sockaddr_in6()
			address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
			address.sin6_family = sa_family_t(AF_INET6)
			address.sin6_port = port.bigEndian
			address.sin6_addr = scope == .loopback ? in6addr_loopback : in6addr_any
			result = withUnsafePointer(to: &address) {
				$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
			}
		} else {
			var address = sockaddr_in()
			address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
			address.sin_family = sa_family_t(AF_INET)
			address.sin_port = port.bigEndian
			address.sin_addr.s_addr = (scope == .loopback ? INADDR_LOOPBACK : INADDR_ANY).bigEndian
			result = withUnsafePointer(to: &address) {
				$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
			}
		}
		guard result == 0 else { throw TransportError.errno("bind port \(port)") }
		guard listen(fd, 4) == 0 else { throw TransportError.errno("listen") }
		ok = true
		return fd
	}

	private static func acceptLoop(sockets: [Int32], wake: Int32, onAccept: (TCPStream) -> Void) {
		defer {
			sockets.forEach { Darwin.close($0) }
			Darwin.close(wake)
		}
		var pfds = sockets.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
		pfds.append(pollfd(fd: wake, events: Int16(POLLIN), revents: 0))
		while true {
			for i in pfds.indices { pfds[i].revents = 0 }
			let ready = poll(&pfds, nfds_t(pfds.count), -1)
			if ready < 0 {
				if errno == EINTR { continue }
				Log.transport.error("poll failed: \(String(cString: strerror(errno)), privacy: .public)")
				return
			}
			if pfds.last!.revents != 0 { return }
			for pfd in pfds.dropLast() where pfd.revents & Int16(POLLIN) != 0 {
				var storage = sockaddr_storage()
				var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
				let client = withUnsafeMutablePointer(to: &storage) {
					$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(pfd.fd, $0, &length) }
				}
				guard client >= 0 else { continue }
				let peer = withUnsafePointer(to: &storage) {
					$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { SocketAddress($0)?.description ?? "?" }
				}
				onAccept(TCPStream(fd: client, peer: peer))
			}
		}
	}
}
