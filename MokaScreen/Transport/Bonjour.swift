// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation
import dnssd

// Discovery uses the dns_sd C API rather than Network.framework because every call can be
// scoped to one interface index. Advertising, browsing, and address lookup are all pinned to
// the Thunderbolt Bridge, so a receiver is never found — or reached — over Wi-Fi, and the
// address handed to the BSD socket layer is always a bridge address.

/// Advertises this Mac as a MokaScreen receiver on one interface.
final class BonjourAdvertiser {
	private var ref: DNSServiceRef?

	/// Registers `name` for ``Wire/serviceType`` on `port`, on `interfaceIndex` only.
	init(name: String, port: UInt16, interfaceIndex: UInt32) throws {
		var ref: DNSServiceRef?
		let error = DNSServiceRegister(&ref, 0, interfaceIndex, name, Wire.serviceType, nil, nil, port.bigEndian, 0, nil, nil, nil)
		guard error == kDNSServiceErr_NoError, let ref else {
			throw TransportError.system("Bonjour register", error)
		}
		DNSServiceSetDispatchQueue(ref, .main)
		self.ref = ref
	}

	deinit {
		if let ref { DNSServiceRefDeallocate(ref) }
	}
}

/// Finds MokaScreen receivers on one interface.
@MainActor
final class BonjourBrowser {
	private var ref: DNSServiceRef?
	private let interfaceIndex: UInt32
	private let onChange: ([String]) -> Void
	private var names: Set<String> = []

	/// Starts browsing on `interfaceIndex`. `onChange` receives the sorted service names on every change.
	init(interfaceIndex: UInt32, onChange: @escaping ([String]) -> Void) throws {
		self.interfaceIndex = interfaceIndex
		self.onChange = onChange
		var ref: DNSServiceRef?
		let context = Unmanaged.passUnretained(self).toOpaque()
		let error = DNSServiceBrowse(&ref, 0, interfaceIndex, Wire.serviceType, nil, { _, flags, _, error, name, _, _, context in
			guard error == kDNSServiceErr_NoError, let name, let context else { return }
			let browser = Unmanaged<BonjourBrowser>.fromOpaque(context).takeUnretainedValue()
			MainActor.assumeIsolated {
				browser.update(name: String(cString: name), added: flags & kDNSServiceFlagsAdd != 0, moreComing: flags & kDNSServiceFlagsMoreComing != 0)
			}
		}, context)
		guard error == kDNSServiceErr_NoError, let ref else {
			throw TransportError.system("Bonjour browse", error)
		}
		DNSServiceSetDispatchQueue(ref, .main)
		self.ref = ref
	}

	/// Stops browsing. Must be called before the browser is released, because the callback holds an unretained reference.
	func stop() {
		if let ref { DNSServiceRefDeallocate(ref) }
		ref = nil
	}

	private func update(name: String, added: Bool, moreComing: Bool) {
		if added { names.insert(name) } else { names.remove(name) }
		if !moreComing { onChange(names.sorted()) }
	}

	/// Resolves a service name to its addresses on the browsed interface.
	///
	/// IPv6 link-local addresses come first: they exist as soon as the bridge has link, while
	/// IPv4 link-local addresses take a few seconds to self-assign after the cable is plugged in.
	func resolve(_ name: String, timeout: TimeInterval = 3) async throws -> [SocketAddress] {
		try await BonjourResolution(name: name, interfaceIndex: interfaceIndex, timeout: timeout).run()
	}
}

/// One service-name → addresses lookup: `DNSServiceResolve` for the host and port, then
/// `DNSServiceGetAddrInfo` for the host's addresses, both scoped to the interface.
@MainActor
private final class BonjourResolution {
	private let name: String
	private let interfaceIndex: UInt32
	private let timeout: TimeInterval
	private var resolveRef: DNSServiceRef?
	private var addressRef: DNSServiceRef?
	private var port: UInt16 = 0
	private var addresses: [SocketAddress] = []
	private var continuation: CheckedContinuation<[SocketAddress], Error>?
	private var timeoutTask: Task<Void, Never>?

	init(name: String, interfaceIndex: UInt32, timeout: TimeInterval) {
		self.name = name
		self.interfaceIndex = interfaceIndex
		self.timeout = timeout
	}

	func run() async throws -> [SocketAddress] {
		try await withCheckedThrowingContinuation { continuation in
			self.continuation = continuation
			// The resolution keeps itself alive until it finishes; the C callbacks hold it unretained.
			let context = Unmanaged.passRetained(self).toOpaque()
			var ref: DNSServiceRef?
			let error = DNSServiceResolve(&ref, 0, interfaceIndex, name, Wire.serviceType, "local.", { _, _, _, error, _, host, port, _, _, context in
				let resolution = Unmanaged<BonjourResolution>.fromOpaque(context!).takeUnretainedValue()
				MainActor.assumeIsolated {
					if error == kDNSServiceErr_NoError, let host {
						resolution.resolved(host: String(cString: host), port: UInt16(bigEndian: port))
					} else {
						resolution.finish(.failure(TransportError.system("Bonjour resolve", error)))
					}
				}
			}, context)
			guard error == kDNSServiceErr_NoError, let ref else {
				finish(.failure(TransportError.system("Bonjour resolve", error)))
				return
			}
			DNSServiceSetDispatchQueue(ref, .main)
			resolveRef = ref
			timeoutTask = Task { [timeout] in
				try? await Task.sleep(for: .seconds(timeout))
				self.finish(self.addresses.isEmpty ? .failure(TransportError.timedOut) : .success(self.addresses))
			}
		}
	}

	private func resolved(host: String, port: UInt16) {
		guard addressRef == nil else { return }
		self.port = port
		let context = Unmanaged.passUnretained(self).toOpaque()
		var ref: DNSServiceRef?
		let protocols = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)
		let error = DNSServiceGetAddrInfo(&ref, 0, interfaceIndex, protocols, host, { _, flags, _, error, _, address, _, context in
			let resolution = Unmanaged<BonjourResolution>.fromOpaque(context!).takeUnretainedValue()
			MainActor.assumeIsolated {
				if error == kDNSServiceErr_NoError, flags & kDNSServiceFlagsAdd != 0, let address, let socketAddress = SocketAddress(address) {
					resolution.add(socketAddress, moreComing: flags & kDNSServiceFlagsMoreComing != 0)
				}
			}
		}, context)
		guard error == kDNSServiceErr_NoError, let ref else {
			finish(.failure(TransportError.system("Bonjour address lookup", error)))
			return
		}
		DNSServiceSetDispatchQueue(ref, .main)
		addressRef = ref
	}

	private func add(_ address: SocketAddress, moreComing: Bool) {
		var address = address
		address.port = port
		if address.isIPv6LinkLocal, address.scopeID == 0 {
			address.scopeID = interfaceIndex
		}
		if !addresses.contains(address) {
			addresses.append(address)
		}
		if !moreComing {
			// Both families usually arrive in one batch; give the other family a moment if only one did.
			let families = Set(addresses.map(\.family))
			if families.count == 2 {
				finish(.success(addresses))
			} else {
				Task {
					try? await Task.sleep(for: .milliseconds(150))
					self.finish(.success(self.addresses))
				}
			}
		}
	}

	private func finish(_ result: Result<[SocketAddress], Error>) {
		guard let continuation else { return }
		self.continuation = nil
		timeoutTask?.cancel()
		if let resolveRef { DNSServiceRefDeallocate(resolveRef) }
		if let addressRef { DNSServiceRefDeallocate(addressRef) }
		resolveRef = nil
		addressRef = nil
		continuation.resume(with: result.map { addresses in
			addresses.sorted { $0.family == AF_INET6 && $1.family != AF_INET6 }
		})
		Unmanaged.passUnretained(self).release()
	}
}
