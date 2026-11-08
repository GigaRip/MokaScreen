// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation

/// A reliable, ordered, full-duplex byte stream between the two Macs.
///
/// Calls block. One thread may read while others write; concurrent writes are
/// serialized by the stream, so a gathered write is never interleaved with another.
/// Everything above `Transport/` talks to this protocol, so the wire layer can
/// change without touching capture or presentation.
protocol ByteStream: AnyObject {
	/// A human-readable description of the remote end, for status and logs.
	var peerDescription: String { get }

	/// Writes every byte of `chunks`, in order, as one uninterrupted sequence.
	/// - Throws: ``TransportError`` if the connection fails or is closed.
	func write(_ chunks: UnsafeBufferPointer<UnsafeRawBufferPointer>) throws

	/// Reads exactly `count` bytes into `buffer`.
	/// - Throws: ``TransportError/closed`` on a clean end of stream, or another ``TransportError``.
	func read(into buffer: UnsafeMutableRawPointer, count: Int) throws

	/// Shuts the stream down in both directions, unblocking any pending read or write.
	func close()
}

extension ByteStream {
	/// Writes a single contiguous region.
	func write(_ bytes: UnsafeRawBufferPointer) throws {
		try withUnsafeTemporaryAllocation(of: UnsafeRawBufferPointer.self, capacity: 1) { chunks in
			chunks[0] = bytes
			try write(UnsafeBufferPointer(chunks))
		}
	}

	/// Encodes a 32-byte header with `encode` and writes it.
	func writeHeader(_ encode: (UnsafeMutableRawPointer) -> Void) throws {
		try withUnsafeTemporaryAllocation(byteCount: Wire.headerSize, alignment: 8) { header in
			encode(header.baseAddress!)
			try write(UnsafeRawBufferPointer(header))
		}
	}

	/// Reads one 32-byte header and hands it to `decode`.
	func readHeader<T>(_ decode: (UnsafeRawPointer) throws -> T) throws -> T {
		try withUnsafeTemporaryAllocation(byteCount: Wire.headerSize, alignment: 8) { header in
			try read(into: header.baseAddress!, count: Wire.headerSize)
			return try decode(header.baseAddress!)
		}
	}
}

/// Failures of the byte stream.
enum TransportError: Error, CustomStringConvertible {
	case closed
	case timedOut
	case system(String, Int32)
	case unresolvable(String)

	var description: String {
		switch self {
		case .closed: "Connection closed"
		case .timedOut: "Connection timed out"
		case .system(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
		case .unresolvable(let host): "Cannot resolve \(host)"
		}
	}

	static func errno(_ operation: String) -> TransportError {
		.system(operation, Darwin.errno)
	}
}
