import Foundation

func frame(_ command: UInt8, _ payload: [UInt8]) -> Data {
    let length = UInt8(payload.count)
    let checksum = payload.reduce(command ^ length, ^)
    return Data([0x55, 0x55, command, length] + payload + [checksum, 0xAA, 0xAA])
}

@main
struct DecoderRegressionTests {
    static func main() {
        let first = frame(0xB5, [1, 2, 3, 4])
        let second = frame(0x48, [0x10, 0x01])
        let stream = first + second
        for split in 0...stream.count {
            var decoder = NiimbotPacketDecoder()
            let packets = decoder.append(Data(stream.prefix(split)))
                + decoder.append(Data(stream.dropFirst(split)))
            precondition(packets.count == 2)
            precondition(packets[0].command == 0xB5 && packets[0].data == Data([1, 2, 3, 4]))
            precondition(packets[1].command == 0x48 && packets[1].data.startIndex == 0)
            precondition(packets[1].data[0] == 0x10 && packets[1].data[1] == 0x01)
        }
        var decoder = NiimbotPacketDecoder()
        var packets: [NiimbotPacketDecoder.Packet] = []
        for byte in Data([0x03, 0xAA, 0x55, 0x00]) + stream {
            packets += decoder.append(Data([byte]))
        }
        precondition(packets.count == 2)
        var sliced = Data([0, 0]) + stream
        sliced.removeFirst(2)
        decoder.reset()
        precondition(decoder.append(sliced).count == 2)
        decoder.reset()
        precondition(decoder.append(first + second.prefix(5)).count == 1)
        precondition(decoder.append(Data(second.dropFirst(5))).count == 1)
        _ = decoder.append(Data([0x55, 0x55, 0x48]))
        decoder.reset()
        precondition(decoder.append(second).count == 1)
        for _ in 0..<1000 { precondition(decoder.append(stream).count == 2) }
        let large = frame(0x48, Array(repeating: 0x55, count: 255))
        precondition(decoder.append(large).first?.data.count == 255)
        precondition(decoder.append(frame(0x31, [])).first?.data.isEmpty == true)
        print("PASS: fragmentation, concatenation, resynchronization, nonzero indices, reset and repeated replies.")
    }
}
