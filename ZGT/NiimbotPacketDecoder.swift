import Foundation

struct NiimbotPacketDecoder {
    struct Packet {
        let command: UInt8
        let data: Data
    }

    private var buffer = Data()

    mutating func append(_ chunk: Data) -> [Packet] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)

        var packets: [Packet] = []

        while true {
            // Sincroniza con el encabezado NIIMBOT 0x55 0x55 sin asumir
            // que CoreBluetooth entrega una trama completa por callback.
            while buffer.count >= 2 &&
                    !(buffer[buffer.startIndex] == 0x55 &&
                      buffer[buffer.index(after: buffer.startIndex)] == 0x55) {
                buffer.removeFirst()
            }

            guard buffer.count >= 4 else { break }

            let command = buffer[buffer.index(buffer.startIndex, offsetBy: 2)]
            let length = Int(buffer[buffer.index(buffer.startIndex, offsetBy: 3)])
            let frameLength = 7 + length

            guard buffer.count >= frameLength else { break }

            let crcIndex = 4 + length
            let tail1Index = 5 + length
            let tail2Index = 6 + length

            guard buffer[buffer.index(buffer.startIndex, offsetBy: tail1Index)] == 0xAA,
                  buffer[buffer.index(buffer.startIndex, offsetBy: tail2Index)] == 0xAA else {
                // Trama desalineada: avanza un byte y vuelve a buscar cabecera.
                buffer.removeFirst()
                continue
            }

            let dataStart = buffer.index(buffer.startIndex, offsetBy: 4)
            let dataEnd = buffer.index(dataStart, offsetBy: length)
            let payload = Data(buffer[dataStart..<dataEnd])

            var crc = command ^ UInt8(length)
            for byte in payload {
                crc ^= byte
            }

            guard buffer[buffer.index(buffer.startIndex, offsetBy: crcIndex)] == crc else {
                buffer.removeFirst()
                continue
            }

            packets.append(Packet(command: command, data: payload))
            buffer.removeFirst(frameLength)
        }

        // Defensa adicional ante ruido BLE sostenido.
        if buffer.count > 4096 {
            if let lastHeader = buffer.indices.dropLast().last(where: { index in
                buffer[index] == 0x55 &&
                buffer[buffer.index(after: index)] == 0x55
            }) {
                buffer = Data(buffer[lastHeader...])
            } else {
                buffer.removeAll(keepingCapacity: true)
            }
        }

        return packets
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}
