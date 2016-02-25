//
//  HTTP2.swift
//  PerfectLib
//
//  Created by Kyle Jessup on 2016-02-18.
//  Copyright © 2016 PerfectlySoft. All rights reserved.
//
//	This program is free software: you can redistribute it and/or modify
//	it under the terms of the GNU Affero General Public License as
//	published by the Free Software Foundation, either version 3 of the
//	License, or (at your option) any later version, as supplemented by the
//	Perfect Additional Terms.
//
//	This program is distributed in the hope that it will be useful,
//	but WITHOUT ANY WARRANTY; without even the implied warranty of
//	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//	GNU Affero General Public License, as supplemented by the
//	Perfect Additional Terms, for more details.
//
//	You should have received a copy of the GNU Affero General Public License
//	and the Perfect Additional Terms that immediately follow the terms and
//	conditions of the GNU Affero General Public License along with this
//	program. If not, see <http://www.perfect.org/AGPL_3_0_With_Perfect_Additional_Terms.txt>.
//

// NOTE: This HTTP/2 client is competent enough to operate with Apple's push notification service, but
// still lacks some functionality to make it general purpose. Consider it a work in-progress.

#if os(Linux)
import SwiftGlibc
#endif

let HTTP2_DATA = UInt8(0x0)
let HTTP2_HEADERS = UInt8(0x1)
let HTTP2_PRIORITY = UInt8(0x2)
let HTTP2_RST_STREAM = UInt8(0x3)
let HTTP2_SETTINGS = UInt8(0x4)
let HTTP2_PUSH_PROMISE = UInt8(0x5)
let HTTP2_PING = UInt8(0x6)
let HTTP2_GOAWAY = UInt8(0x7)
let HTTP2_WINDOW_UPDATE = UInt8(0x8)
let HTTP2_CONTINUATION = UInt8(0x9)

let HTTP2_END_STREAM = UInt8(0x1)
let HTTP2_SETTINGS_ACK = HTTP2_END_STREAM
let HTTP2_PING_ACK = HTTP2_END_STREAM
let HTTP2_END_HEADERS = UInt8(0x4)
let HTTP2_PADDED = UInt8(0x8)
let HTTP2_FLAG_PRIORITY = UInt8(0x20)

public struct HTTP2Frame {
	let length: UInt32 // 24-bit
	let type: UInt8
	let flags: UInt8
	let streamId: UInt32 // 31-bit
	var payload: [UInt8]?

	func headerBytes() -> [UInt8] {
		var data = [UInt8]()

		let l = htonl(length) >> 8
		data.append(UInt8(l & 0xFF))
		data.append(UInt8((l >> 8) & 0xFF))
		data.append(UInt8((l >> 16) & 0xFF))

		data.append(type)
		data.append(flags)

		let s = htonl(streamId)
		data.append(UInt8(s & 0xFF))
		data.append(UInt8((s >> 8) & 0xFF))
		data.append(UInt8((s >> 16) & 0xFF))
		data.append(UInt8((s >> 24) & 0xFF))
		return data
	}
}

class HTTP2Connection: WebConnection {

	weak var client: HTTP2Client?
	var status = (200, "OK")

	init(client: HTTP2Client) {
		self.client = client
	}

	/// The TCP based connection
	var connection: NetTCP {
		if let c = self.client {
			return c.net
		}
		return NetTCP() // return non-connected
	}
	/// The parameters sent by the client
	var requestParams = [String:String]()
	/// Any non mime based request body data
	var stdin: [UInt8]? { return nil }
	/// Parsed mime based body data
	var mimes: MimeReader? { return nil }

	/// Set the response status code and message. For example, 200, "OK".
	func setStatus(code: Int, msg: String) {
		self.status = (code, msg)
	}
	/// Get the response status code and message.
	func getStatus() -> (Int, String) { return self.status }
	/// Add a response header which will be sent to the client.
	func writeHeaderLine(h: String) {}
	/// Send header bytes to the client.
	func writeHeaderBytes(b: [UInt8]) {}
	/// Write body bytes ot the client. Any pending header data will be written first.
	func writeBodyBytes(b: [UInt8]) {}

}

public class HTTP2WebRequest: WebRequest {

}

public class HTTP2WebResponse: WebResponse, HeaderListener {

	public func addHeader(name: [UInt8], value: [UInt8], sensitive: Bool) {
		let n = UTF8Encoding.encode(name)
		let v = UTF8Encoding.encode(value)

		print("\(n): \(v)")

		switch n {
		case ":status":
			self.setStatus(Int(v) ?? -1, message: "")
		default:
			headersArray.append((n, v))
		}
	}
}
public class HTTP2Client {

	enum StreamState {
		case None, Idle, ReservedLocal, ReservedRemote, Open, HalfClosedRemote, HalfClosedLocal, Closed
	}

	let net = NetTCPSSL()
	var host = ""
	var timeoutSeconds = 5.0
	var ssl = true
	var streams = [UInt32:StreamState]()
	var streamCounter = UInt32(0)

	let frameReadEvent = Threading.Event()
	var frameQueue = [HTTP2Frame]()
	var frameReadOK = false

	var newStreamId: UInt32 {
		streamCounter += 1
		streams[streamCounter] = .None
		return streamCounter
	}

	public init() {

	}

	func dequeueFrame(timeoutSeconds: Double) -> HTTP2Frame? {
		var frame: HTTP2Frame? = nil

		self.frameReadEvent.doWithLock {
			if self.frameQueue.count == 0 {
				self.frameReadEvent.wait(Int(timeoutSeconds * 1000.0))
			}
			if self.frameQueue.count > 0 {
				frame = self.frameQueue.removeFirst()
			}
		}

		return frame
	}

	func dequeueFrame(timeoutSeconds: Double, streamId: UInt32) -> HTTP2Frame? {
		var frame: HTTP2Frame? = nil

		self.frameReadEvent.doWithLock {
			if self.frameQueue.count == 0 {
				self.frameReadEvent.wait(Int(timeoutSeconds * 1000.0))
			}
			if self.frameQueue.count > 0 {
				for i in 0..<self.frameQueue.count {
					let frameTest = self.frameQueue[i]
					if frameTest.streamId == streamId {
						self.frameQueue.removeAtIndex(i)
						frame = frameTest
						break
					}
				}
			}
		}

		return frame
	}

	func processSettingsPayload(b: Bytes) {
		while b.availableExportBytes >= 6 {
			let identifier = ntohs(b.export16Bits())
			let value = ntohl(b.export32Bits())

			print("Setting \(identifier) \(value)")
		}
	}

	func readOneFrame() {
		Threading.dispatchBlock {
			self.readHTTP2Frame(-1) { [weak self]
				f in

				if let frame = f {
					self?.frameReadEvent.doWithLock {

						switch frame.type {
						case HTTP2_SETTINGS:

							let endStream = (frame.flags & HTTP2_SETTINGS_ACK) != 0

							if !endStream { // ACK settings receipt
								if let payload = frame.payload {
									self?.processSettingsPayload(Bytes(existingBytes: payload))
								}
								let response = HTTP2Frame(length: 0, type: HTTP2_SETTINGS, flags: HTTP2_SETTINGS_ACK, streamId: 0, payload: nil)
								self?.writeHTTP2Frame(response) {
									b in

									self?.readOneFrame()
								}
							} else { // ACK of our settings frame
								self?.readOneFrame()
							}

						case HTTP2_PING:

							let endStream = (frame.flags & HTTP2_PING_ACK) != 0

							if !endStream { // ACK ping receipt
								if let payload = frame.payload {
									self?.processSettingsPayload(Bytes(existingBytes: payload))
								}
								let response = HTTP2Frame(length: frame.length, type: HTTP2_PING, flags: HTTP2_PING_ACK, streamId: 0, payload: frame.payload)
								self?.writeHTTP2Frame(response) {
									b in

									self?.readOneFrame()
								}
							} else { // ACK of our ping frame
								self?.readOneFrame()
							}

						default:

							self?.frameQueue.append(frame)
							self?.frameReadOK = true
							self?.frameReadEvent.broadcast()
						}
					}
				} else { // network error
					self?.frameReadEvent.doWithLock {
						self?.net.close()
						self?.frameReadOK = false
						self?.frameReadEvent.broadcast()
					}
				}
			}
		}
	}

	func startReadThread() {
		Threading.dispatchBlock { [weak self] in

			// dbg
			defer {
				print("~HTTP2Client.startReadThread")
			}

			if let net = self?.net {

				while net.fd.isValid {

					if let s = self {

						s.frameReadEvent.doWithLock {
							s.frameReadOK = false
							s.readOneFrame()
							if !s.frameReadOK && net.fd.isValid {
								s.frameReadEvent.wait()
							}
						}
						if !s.frameReadOK {
							net.close()
							break
						}

					} else {
						net.close()
						break
					}
				}
			}
		}
	}

	public func close() {
		net.close()
	}

	public var isConnected: Bool {
		return self.net.fd.isValid
	}

	public func connect(host: String, port: UInt16, ssl: Bool, timeoutSeconds: Double, callback: (Bool) -> ()) {
		self.host = host
		self.ssl = ssl
		self.timeoutSeconds = timeoutSeconds

		do {
			try net.connect(host, port: port, timeoutSeconds: timeoutSeconds) {
				n in

				if let net = n as? NetTCPSSL {

					if ssl {
						net.beginSSL {
							b in

							if b {
								self.completeConnect(callback)
							} else {
								callback(false)
							}
						}
					} else {
						self.completeConnect(callback)
					}

				} else {
					callback(false)
				}
			}
		} catch {
			callback(false)
		}
	}

	public func createRequest() -> HTTP2WebRequest {
		return HTTP2WebRequest(HTTP2Connection(client: self))
	}

	func awaitResponse(streamId: UInt32, request: WebRequest, callback: (WebResponse?, String?) -> ()) {
		let response = HTTP2WebResponse(request.connection, request: request)
		var streamOpen = true
		while streamOpen {
			let f = self.dequeueFrame(self.timeoutSeconds, streamId: streamId)

			if let frame = f {

				switch frame.type {
				case HTTP2_GOAWAY:
					let bytes = Bytes(existingBytes: frame.payload!)
					let streamId = ntohl(bytes.export32Bits())
					let errorCode = ntohl(bytes.export32Bits())
					var message = ""
					if bytes.availableExportBytes > 0 {
						message = UTF8Encoding.encode(bytes.exportBytes(bytes.availableExportBytes))
					}

					let bytes2 = Bytes(initialSize: 8)
					bytes2.import32Bits(htonl(streamId))
					bytes2.import32Bits(0)
					let frame2 = HTTP2Frame(length: 8, type: HTTP2_GOAWAY, flags: 0, streamId: streamId, payload: bytes2.data)
					self.writeHTTP2Frame(frame2) {
						b in

						self.close()
					}
					callback(nil, "\(errorCode) \(message)")
					streamOpen = false
				case HTTP2_HEADERS:
					let padded = (frame.flags & HTTP2_PADDED) != 0
//					let priority = (frame.flags & HTTP2_PRIORITY) != 0
//					let end = (frame.flags & HTTP2_END_HEADERS) != 0

					if let ba = frame.payload where ba.count > 0 {
						let bytes = Bytes(existingBytes: ba)
						var padLength = UInt8(0)
						//										var streamDep = UInt32(0)
						//										var weight = UInt8(0)

						if padded {
							padLength = bytes.export8Bits()
						}
						//										if priority {
						//											streamDep = bytes.export32Bits()
						//											weight = bytes.export8Bits()
						//										}
						self.decodeHeaders(bytes, endPosition: ba.count - Int(padLength), listener: response)
					}
					streamOpen = (frame.flags & HTTP2_END_STREAM) == 0
					if !streamOpen {
						callback(response, nil)
					}
				case HTTP2_DATA:
					if frame.length > 0 {
						response.bodyData.appendContentsOf(frame.payload!)
						print("\(UTF8Encoding.encode(response.bodyData))")
					}
					streamOpen = (frame.flags & HTTP2_END_STREAM) == 0
					if !streamOpen {
						callback(response, nil)
					}
				default:
					callback(nil, "Unexpected frame type \(frame.type)")
				}

			} else {
				self.close()
				callback(nil, "Connection dropped")
			}
		}
	}

	public func sendRequest(request: WebRequest, callback: (WebResponse?, String?) -> ()) {
		let streamId = self.newStreamId
		self.streams[streamId] = .Idle

		let headerBytes = Bytes()
		let encoder = HPACKEncoder()

		let method = request.requestMethod()
		let scheme = ssl ? "https" : "http"
		let path = request.requestURI()

		do {

			try encoder.encodeHeader(headerBytes, name: ":method", value: method)
			try encoder.encodeHeader(headerBytes, name: ":scheme", value: scheme)
			try encoder.encodeHeader(headerBytes, name: ":path", value: path, sensitive: true)
			try encoder.encodeHeader(headerBytes, name: "host", value: self.host)
			try encoder.encodeHeader(headerBytes, name: "content-length", value: "\(request.postBodyBytes.count)")

			for (name, value) in request.headers {
				let n = UTF8Encoding.decode(name.lowercaseString)
				let v = UTF8Encoding.decode(value)

				try encoder.encodeHeader(headerBytes, name: n, value: v, sensitive: false)
			}

		} catch {
			callback(nil, "Header encoding exception \(error)")
			return
		}
		let hasData = request.postBodyBytes.count > 0
		let frame = HTTP2Frame(length: UInt32(headerBytes.data.count), type: HTTP2_HEADERS, flags: HTTP2_END_HEADERS | (hasData ? 0 : HTTP2_END_STREAM), streamId: streamId, payload: headerBytes.data)
		self.writeHTTP2Frame(frame) { [weak self]
			b in

			guard b else {
				callback(nil, "Unable to write frame")
				return
			}
			guard let s = self else {
				callback(nil, nil)
				return
			}
			s.streams[streamId] = .Open
			if hasData {

				let frame2 = HTTP2Frame(length: UInt32(request.postBodyBytes.count), type: HTTP2_DATA, flags: HTTP2_END_STREAM, streamId: streamId, payload: request.postBodyBytes)
				s.writeHTTP2Frame(frame2) { [weak self]
					b in

					guard let s = self else {
						callback(nil, nil)
						return
					}

					s.awaitResponse(streamId, request: request, callback: callback)
				}

			} else {
				s.awaitResponse(streamId, request: request, callback: callback)
			}
		}
	}

	func completeConnect(callback: (Bool) -> ()) {
		net.writeString("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n") {
			wrote in

			let settings = HTTP2Frame(length: 0, type: HTTP2_SETTINGS, flags: 0, streamId: 0, payload: nil)
			self.writeHTTP2Frame(settings) { [weak self]
				b in

				if b {
					self?.startReadThread()
				}
				callback(b)
			}
		}
	}

	func bytesToHeader(b: [UInt8]) -> HTTP2Frame {
		let payloadLength = (UInt32(b[0]) << 16) + (UInt32(b[1]) << 8) + UInt32(b[2])

		let type = b[3]
		let flags = b[4]
		var sid: UInt32 = UInt32(b[5])
		sid << 8
		sid += UInt32(b[6])
		sid << 8
		sid += UInt32(b[7])
		sid << 8
		sid += UInt32(b[8])

		sid &= ~0x80000000

		return HTTP2Frame(length: payloadLength, type: type, flags: flags, streamId: sid, payload: nil)
	}

	func readHTTP2Frame(timeout: Double, callback: (HTTP2Frame?) -> ()) {
		let net = self.net
		net.readBytesFully(9, timeoutSeconds: timeout) {
			bytes in

			if let b = bytes {

				var header = self.bytesToHeader(b)

				if header.length > 0 {
					net.readBytesFully(Int(header.length), timeoutSeconds: timeout) {
						bytes in

						header.payload = bytes

						callback(header)
					}
				} else {
					callback(header)
				}

			} else {
				callback(nil)
			}
		}
	}

	func writeHTTP2Frame(frame: HTTP2Frame, callback: (Bool) -> ()) {
		if !net.fd.isValid {
			callback(false)
		} else if !net.writeBytesFully(frame.headerBytes()) {
			callback(false)
		} else {
			if let p = frame.payload {
				callback(net.writeBytesFully(p))
			} else {
				callback(true)
			}
		}
	}

	func encodeHeaders(headers: [(String, String)]) -> Bytes {
		let b = Bytes()
		let encoder = HPACKEncoder()
		for header in headers {
			let n = UTF8Encoding.decode(header.0)
			let v = UTF8Encoding.decode(header.1)
			do {
				try encoder.encodeHeader(b, name: n, value: v, sensitive: false)
			} catch {
				self.close()
				break
			}
		}
		return b
	}

	func decodeHeaders(from: Bytes, endPosition: Int, listener: HeaderListener) {
		let decoder = HPACKDecoder()
		do {
			try decoder.decode(from, headerListener: listener)
		} catch {
			self.close()
		}
	}
}
