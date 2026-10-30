import CryptoKit
import Foundation

/// RFC 6455, the part the phone host uses: the opening handshake, masked
/// frames in, unmasked text frames out, ping/pong and close.
enum PhoneWebSocket {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    static let maxMessage = 8 * 1024 * 1024

    /// The 101 response for an upgrade request, or nil if it isn't one.
    static func handshake(for request: PhoneHTTPRequest) -> PhoneHTTPResponse? {
        guard request.method == "GET",
              request.header("upgrade")?.lowercased() == "websocket",
              request.header("connection")?.lowercased().contains("upgrade") == true,
              request.header("sec-websocket-version") == "13",
              let key = request.header("sec-websocket-key"), !key.isEmpty else { return nil }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + guid).utf8))).base64EncodedString()
        return PhoneHTTPResponse(status: 101, headers: [
            "Upgrade": "websocket", "Connection": "Upgrade", "Sec-WebSocket-Accept": accept,
        ])
    }

    /// The 101 head has no body and the connection stays open, so it isn't `serialized()`.
    static func handshakeBytes(_ response: PhoneHTTPResponse) -> Data {
        var head = "HTTP/1.1 101 Switching Protocols\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8)
    }

    enum Event: Equatable {
        case text(String)
        case ping(Data)
        case pong
        case close
    }

    enum Opcode: UInt8 {
        case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
    }

    static func frame(_ opcode: Opcode, _ payload: Data = Data()) -> Data {
        var out = Data([0x80 | opcode.rawValue])
        switch payload.count {
        case 0..<126:
            out.append(UInt8(payload.count))
        case 126..<65_536:
            out.append(126)
            out.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        default:
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((payload.count >> shift) & 0xFF)) }
        }
        return out + payload
    }

    static func text(_ text: String) -> Data { frame(.text, Data(text.utf8)) }

    /// Accumulates bytes and yields whole messages.
    struct Decoder {
        private var buffer = Data()
        private var fragments = Data()
        private var fragmentOpcode: Opcode?
        private(set) var failed = false

        mutating func feed(_ data: Data) -> [Event] {
            buffer.append(data)
            var events: [Event] = []
            while !failed, let event = next() { events.append(event) }
            return events
        }

        private mutating func next() -> Event? {
            while true {
                guard buffer.count >= 2 else { return nil }
                let b = [UInt8](buffer.prefix(14))
                let fin = b[0] & 0x80 != 0
                guard b[0] & 0x70 == 0, let opcode = Opcode(rawValue: b[0] & 0x0F) else { return fail() }
                // Clients must mask; an unmasked frame is a protocol error.
                guard b[1] & 0x80 != 0 else { return fail() }
                var length = Int(b[1] & 0x7F)
                var offset = 2
                if length == 126 {
                    guard b.count >= 4 else { return nil }
                    length = Int(b[2]) << 8 | Int(b[3])
                    offset = 4
                } else if length == 127 {
                    guard b.count >= 10 else { return nil }
                    length = 0
                    for i in 2..<10 { length = length << 8 | Int(b[i]) }
                    guard length >= 0, length <= PhoneWebSocket.maxMessage else { return fail() }
                    offset = 10
                }
                guard length <= PhoneWebSocket.maxMessage else { return fail() }
                guard buffer.count >= offset + 4 + length else { return nil }
                let all = [UInt8](buffer.prefix(offset + 4 + length))
                let mask = Array(all[offset..<offset + 4])
                var payload = Data(count: length)
                for i in 0..<length { payload[i] = all[offset + 4 + i] ^ mask[i % 4] }
                buffer.removeFirst(offset + 4 + length)

                switch opcode {
                case .ping: return .ping(payload)
                case .pong: return .pong
                case .close: return .close
                case .text, .binary:
                    if fin { return message(opcode, payload) }
                    fragmentOpcode = opcode
                    fragments = payload
                case .continuation:
                    guard let started = fragmentOpcode else { return fail() }
                    fragments.append(payload)
                    guard fragments.count <= PhoneWebSocket.maxMessage else { return fail() }
                    if fin {
                        let whole = fragments
                        fragments = Data()
                        fragmentOpcode = nil
                        return message(started, whole)
                    }
                }
            }
        }

        private func message(_ opcode: Opcode, _ payload: Data) -> Event? {
            // Effect RPC's JSON serialization is text; a binary frame carries the same UTF-8.
            .text(String(decoding: payload, as: UTF8.self))
        }

        private mutating func fail() -> Event? {
            failed = true
            return .close
        }
    }
}
