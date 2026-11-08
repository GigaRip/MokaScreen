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

/// A ``ByteStream`` over one blocking BSD TCP socket.
///
/// Measured on Thunderbolt 5 between two M5 Max MacBook Pros, a single TCP stream
/// reaches ~69 Gbps and is link-bound, so MokaScreen uses exactly one connection.
final class TCPStream: ByteStream {
	let peerDescription: String
	private let fd: Int32
	private let writeLock = NSLock()
	private let closed = OSAllocatedUnfairLock(initialState: false)

	/// Wraps a connected socket and applies MokaScreen's socket options.
	init(fd: Int32, peer: String) {
		self.fd = fd
		self.peerDescription = peer
		Self.configure(fd)
	}

	deinit {
		Darwin.close(fd)
	}

	/// Connects to `address`, optionally pinned to one network interface.
	///
	/// - Parameter interfaceIndex: When non-zero, the socket may only use this interface, so
	///   traffic cannot silently fall back to Wi-Fi if the Thunderbolt link goes down.
	static func connect(to address: SocketAddress, interfaceIndex: UInt32 = 0, timeout: TimeInterval = 3) throws -> TCPStream {
		let fd = socket(address.family, SOCK_STREAM, IPPROTO_TCP)
		guard fd >= 0 else { throw TransportError.errno("socket") }
		var ok = false
		defer { if !ok { Darwin.close(fd) } }

		if interfaceIndex != 0 {
			try bind(fd, toInterface: interfaceIndex, family: address.family)
		}

		// Non-blocking only for the connect, so the timeout is enforceable; the stream itself blocks.
		let flags = fcntl(fd, F_GETFL)
		_ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
		let result = address.withSockaddr { Darwin.connect(fd, $0, address.length) }
		if result != 0 {
			guard errno == EINPROGRESS else { throw TransportError.errno("connect") }
			var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
			let ready = poll(&pfd, 1, Int32(timeout * 1000))
			if ready == 0 { throw TransportError.timedOut }
			if ready < 0 { throw TransportError.errno("poll") }
			var error: Int32 = 0
			var length = socklen_t(MemoryLayout<Int32>.size)
			getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
			if error != 0 { throw TransportError.system("connect", error) }
		}
		_ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)

		ok = true
		return TCPStream(fd: fd, peer: address.description)
	}

	/// Restricts a socket to one interface, for both outgoing and (on a listener) incoming traffic.
	static func bind(_ fd: Int32, toInterface index: UInt32, family: Int32) throws {
		var index = index
		let size = socklen_t(MemoryLayout<UInt32>.size)
		let result = family == AF_INET6
			? setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &index, size)
			: setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, size)
		guard result == 0 else { throw TransportError.errno("bind to interface") }
	}

	/// Bounds how long a read may block; `nil` blocks indefinitely. Used during the handshake,
	/// so a peer that accepts but never answers cannot stall a connection attempt.
	func setReadTimeout(_ seconds: TimeInterval?) {
		var timeout = timeval(tv_sec: Int(seconds ?? 0), tv_usec: Int32(((seconds ?? 0) - Double(Int(seconds ?? 0))) * 1e6))
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
	}

	private static func configure(_ fd: Int32) {
		func set(_ level: Int32, _ option: Int32, _ value: Int32) {
			var value = value
			setsockopt(fd, level, option, &value, socklen_t(MemoryLayout<Int32>.size))
		}
		// Without this, writing to a peer that vanished raises SIGPIPE and kills the app.
		set(SOL_SOCKET, SO_NOSIGPIPE, 1)
		// Every write is a complete, latency-critical frame; Nagle would hold back its tail.
		set(IPPROTO_TCP, TCP_NODELAY, 1)
		// The link's bandwidth-delay product is well under 1 MB (~69 Gbps × ~50 µs). 4 MB keeps the
		// pipe full without letting the kernel queue more than ~0.5 ms of stale pixels.
		set(SOL_SOCKET, SO_SNDBUF, 4 << 20)
		set(SOL_SOCKET, SO_RCVBUF, 4 << 20)
		// A peer that sleeps or loses the cable never sends a FIN. Keepalive catches an idle dead
		// peer within ~5 s, and TCP_RXT_CONNDROPTIME aborts a write stuck retransmitting after 3 s,
		// so both sides fall back to reconnecting instead of hanging.
		set(SOL_SOCKET, SO_KEEPALIVE, 1)
		set(IPPROTO_TCP, TCP_KEEPALIVE, 2)
		set(IPPROTO_TCP, TCP_KEEPINTVL, 1)
		set(IPPROTO_TCP, TCP_KEEPCNT, 3)
		set(IPPROTO_TCP, TCP_RXT_CONNDROPTIME, 3)
	}

	func write(_ chunks: UnsafeBufferPointer<UnsafeRawBufferPointer>) throws {
		writeLock.lock()
		defer { writeLock.unlock() }

		let batchLimit = Int(IOV_MAX)
		try withUnsafeTemporaryAllocation(of: iovec.self, capacity: min(chunks.count, batchLimit)) { iov in
			var next = 0
			while next < chunks.count {
				var count = 0
				while count < iov.count, next + count < chunks.count {
					let chunk = chunks[next + count]
					iov[count] = iovec(iov_base: UnsafeMutableRawPointer(mutating: chunk.baseAddress), iov_len: chunk.count)
					count += 1
				}
				try writeAll(iov.baseAddress!, count)
				next += count
			}
		}
	}

	/// Writes a batch of iovecs, resuming after partial writes.
	private func writeAll(_ iov: UnsafeMutablePointer<iovec>, _ count: Int) throws {
		var first = 0
		while first < count {
			let written = writev(fd, iov + first, Int32(count - first))
			if written < 0 {
				if errno == EINTR { continue }
				throw closed.withLock({ $0 }) ? TransportError.closed : TransportError.errno("write")
			}
			var remaining = written
			while first < count, remaining >= iov[first].iov_len {
				remaining -= iov[first].iov_len
				first += 1
			}
			if remaining > 0 {
				iov[first].iov_base += remaining
				iov[first].iov_len -= remaining
			}
		}
	}

	func read(into buffer: UnsafeMutableRawPointer, count: Int) throws {
		var offset = 0
		while offset < count {
			let received = recv(fd, buffer + offset, count - offset, MSG_WAITALL)
			if received > 0 {
				offset += received
			} else if received == 0 {
				throw TransportError.closed
			} else if errno == EAGAIN {
				throw TransportError.timedOut
			} else if errno != EINTR {
				throw closed.withLock({ $0 }) ? TransportError.closed : TransportError.errno("read")
			}
		}
	}

	func close() {
		let wasClosed = closed.withLock { state in
			defer { state = true }
			return state
		}
		// shutdown, not close: other threads may be blocked on this descriptor, and closing it
		// would let the number be reused underneath them. The descriptor is closed in deinit.
		if !wasClosed {
			shutdown(fd, SHUT_RDWR)
		}
	}
}
