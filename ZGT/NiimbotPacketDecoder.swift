import Foundation

/// Data retains its indices after removeFirst(). Offsets must be relative
/// to startIndex, including after fragmented or concatenated BLE replies.
struct NiimbotPacketDecoder {
    struct Packet {
        let command: UInt8
        let data: Data
    }
    private var buffer = Data()

    mutating func reset() { buffer = Data() }

    mutating func append(_ value: Data) -> [Packet] {
        buffer.append(value)
        var packets: [Packet] = []
        while buffer.count >= 7 {
            let start = buffer.startIndex
            guard buffer[start] == 0x55, buffer[start + 1] == 0x55 else {
                buffer.removeFirst()
                continue
            }
            let length = Int(buffer[start + 3])
            let frameLength = 7 + length
            guard buffer.count >= frameLength else { break }
            let command = buffer[start + 2]
            // Rebase the payload for existing zero-based packet consumers.
            let payload = Data(buffer[(start + 4)..<(start + 4 + length)])
            buffer.removeFirst(frameLength)
            packets.append(Packet(command: command, data: payload))
        }
        if buffer.isEmpty { reset() }
        return packets
    }
}
