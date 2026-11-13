import Foundation
import Darwin
import CryptoKit

protocol WebSocketByteStream: AnyObject {
    func write(_ data: Data) throws
    func readExactly(_ count: Int) throws -> Data
}

/// A bounded JSON-RPC client for Codex's WebSocket-over-Unix transport.
/// Used on the scanner's background task, with one deadline for the whole scan.
final class LocalWebSocket {
    private let stream: any WebSocketByteStream
    private static let maximumMessageBytes = 8 * 1024 * 1024

    init(stream: any WebSocketByteStream) { self.stream = stream }

    static func connect(to url: URL, timeoutMilliseconds: Int) throws -> LocalWebSocket {
        let stream = try LocalSocketStream.connect(to: url.resolvingSymlinksInPath().path,
                                                   timeoutMilliseconds: timeoutMilliseconds)
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let headers = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try stream.write(Data(headers.utf8))
        let headerData = try stream.readHeaders()
        let lines = String(decoding: headerData, as: UTF8.self).components(separatedBy: "\r\n")
        let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let accepted = lines.contains { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && parts[0].lowercased() == "sec-websocket-accept"
                && parts[1].trimmingCharacters(in: .whitespaces) == expected
        }
        guard lines.first?.split(separator: " ").dropFirst().first == "101", accepted else {
            throw StatusConnectionError("The local server rejected its WebSocket handshake.")
        }
        return LocalWebSocket(stream: stream)
    }

    func request(id: Int, method: String, params: [String: Any],
                 onMessage: (([String: Any]) -> Void)? = nil) throws -> [String: Any] {
        try sendJSON(["id": id, "method": method, "params": params])
        while true {
            let message = try receiveJSON()
            guard message["method"] == nil, message["id"] as? Int == id else {
                onMessage?(message)
                continue
            }
            if message["error"] != nil { throw StatusConnectionError("The server rejected the request. Refresh or open the session for details.") }
            guard let result = message["result"] as? [String: Any] else {
                throw StatusConnectionError("Unexpected response from the local server.")
            }
            return result
        }
    }

    func sendJSON(_ object: [String: Any]) throws {
        try sendFrame(try JSONSerialization.data(withJSONObject: object), opcode: 1)
    }

    private func sendFrame(_ payload: Data, opcode: UInt8) throws {
        guard payload.count <= Self.maximumMessageBytes else { throw StatusConnectionError("Status message is too large.") }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= 65535 {
            frame.append(0xfe)
            frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 255))
        } else {
            frame.append(0xff)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(payload.count) >> shift) & 255)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try stream.write(frame)
    }

    func receiveJSON() throws -> [String: Any] {
        var message = Data()
        var started = false
        while true {
            let header = try stream.readExactly(2)
            let final = header[0] & 0x80 != 0
            let opcode = header[0] & 0x0f
            guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else {
                throw StatusConnectionError("Unsupported WebSocket frame.")
            }
            var length = UInt64(header[1] & 0x7f)
            if length == 126 || length == 127 {
                let bytes = try stream.readExactly(length == 126 ? 2 : 8)
                length = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
            guard length <= Self.maximumMessageBytes,
                  message.count + Int(length) <= Self.maximumMessageBytes else {
                throw StatusConnectionError("Status response is too large.")
            }
            let payload = try stream.readExactly(Int(length))
            if opcode >= 8 {
                guard final, length <= 125 else { throw StatusConnectionError("Invalid WebSocket control frame.") }
                if opcode == 8 { throw StatusConnectionError("The local server closed the status connection.") }
                if opcode == 9 { try sendFrame(payload, opcode: 10) }
                guard opcode == 9 || opcode == 10 else { throw StatusConnectionError("Invalid WebSocket control opcode.") }
                continue
            }
            guard (opcode == 1 && !started) || (opcode == 0 && started) else {
                throw StatusConnectionError("Unexpected WebSocket message.")
            }
            started = true
            message.append(payload)
            if final {
                guard let object = try JSONSerialization.jsonObject(with: message) as? [String: Any] else {
                    throw StatusConnectionError("Invalid status response.")
                }
                return object
            }
        }
    }
}

private final class LocalSocketStream: WebSocketByteStream {
    let descriptor: Int32
    let deadline: TimeInterval
    private var buffer = Data()

    private init(descriptor: Int32, timeoutMilliseconds: Int) {
        self.descriptor = descriptor
        deadline = ProcessInfo.processInfo.systemUptime + Double(timeoutMilliseconds) / 1000
    }

    deinit { close(descriptor) }

    static func connect(to path: String, timeoutMilliseconds: Int) throws -> LocalSocketStream {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let stream = LocalSocketStream(descriptor: fd, timeoutMilliseconds: timeoutMilliseconds)
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            throw POSIXError(.EIO)
        }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(.EIO)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw StatusConnectionError("Codex socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try stream.wait(for: Int16(POLLOUT))
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
        }
        return stream
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(for: Int16(POLLOUT))
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { throw StatusConnectionError("Couldn’t send a status request.") }
                offset += count
            }
        }
    }

    func readExactly(_ count: Int) throws -> Data {
        while buffer.count < count { try receive() }
        let result = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return result
    }

    func readHeaders() throws -> Data {
        let delimiter = Data("\r\n\r\n".utf8)
        while true {
            if let range = buffer.range(of: delimiter) {
                let result = Data(buffer[..<range.upperBound])
                buffer.removeSubrange(..<range.upperBound)
                return result
            }
            guard buffer.count < 16_384 else { throw StatusConnectionError("Invalid WebSocket handshake.") }
            try receive()
        }
    }

    private func receive() throws {
        while true {
            try wait(for: Int16(POLLIN))
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw StatusConnectionError("The local status connection closed.") }
            buffer.append(contentsOf: bytes.prefix(count))
            return
        }
    }

    private func wait(for events: Int16) throws {
        while true {
            let remaining = (deadline - ProcessInfo.processInfo.systemUptime) * 1000
            guard remaining > 0 else { throw StatusConnectionError("The live status request timed out.") }
            var descriptor = pollfd(fd: self.descriptor, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining.rounded(.up), Double(Int32.max))))
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw StatusConnectionError("The live status request timed out.") }
            guard descriptor.revents & Int16(POLLNVAL | POLLERR) == 0 else {
                throw StatusConnectionError("The local status socket is unavailable.")
            }
            return
        }
    }
}

private struct StatusConnectionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
