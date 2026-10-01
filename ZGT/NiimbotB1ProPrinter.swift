import Foundation
import CoreBluetooth
import UIKit

struct NiimbotNativeEvent {
    let type: String
    let message: String

    static func progress(_ message: String) -> Self { .init(type: "progress", message: message) }
    static func connected(_ message: String) -> Self { .init(type: "connected", message: message) }
    static func success(_ message: String) -> Self { .init(type: "success", message: message) }
    static func disconnected(_ message: String) -> Self { .init(type: "disconnected", message: message) }
    static func error(_ message: String) -> Self { .init(type: "error", message: message) }
}

@MainActor
final class NiimbotB1ProPrinter: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private struct Packet {
        let command: UInt8
        let data: [UInt8]
    }

    private struct Candidate {
        let peripheral: CBPeripheral
        let rssi: Int
    }

    private enum PrinterError: LocalizedError {
        case bluetoothUnavailable
        case printerNotFound
        case connectionFailed
        case serviceMissing
        case characteristicMissing
        case notificationsFailed
        case writeUnsupported
        case writeFailed
        case writeTimeout
        case responseTimeout(String)
        case wrongPrinter(Int)
        case invalidImage
        case printUnconfirmed

        var errorDescription: String? {
            switch self {
            case .bluetoothUnavailable:
                return "Activá Bluetooth en el iPhone y volvé a intentar."
            case .printerNotFound:
                return "No se encontró ninguna NIIMBOT B1 Pro. Verificá que esté encendida y cerca del iPhone."
            case .connectionFailed:
                return "No se pudo conectar con la NIIMBOT B1 Pro."
            case .serviceMissing:
                return "La impresora no expone el servicio Bluetooth NIIMBOT esperado."
            case .characteristicMissing:
                return "No se encontró el canal Bluetooth de impresión NIIMBOT."
            case .notificationsFailed:
                return "No se pudieron activar las respuestas Bluetooth de la impresora."
            case .writeUnsupported:
                return "La impresora no admite el modo Bluetooth confirmado requerido por ZGT."
            case .writeFailed:
                return "La B1 Pro rechazó un paquete Bluetooth."
            case .writeTimeout:
                return "El iPhone no confirmó el envío de un paquete Bluetooth."
            case .responseTimeout(let step):
                return "La B1 Pro no confirmó \(step)."
            case .wrongPrinter(let id):
                return "La impresora seleccionada no es una NIIMBOT B1 Pro (ID 4097). Detectada: ID \(id). No se envió ninguna etiqueta."
            case .invalidImage:
                return "La etiqueta recibida por la app no es una imagen PNG válida."
            case .printUnconfirmed:
                return "La B1 Pro no confirmó que la etiqueta terminara de imprimirse."
            }
        }
    }

    private let serviceUUID = CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2")
    private let characteristicUUID = CBUUID(string: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F")
    private let modelIDB1Pro = 4097
    private let width = 576
    private let height = 354
    private let density = 3
    private let labelType = 1
    private let speed = 1

    private let emit: (NiimbotNativeEvent) -> Void
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var candidates: [UUID: Candidate] = [:]
    private var receiveBuffer = Data()
    private var bufferedPackets: [Packet] = []

    private var powerWaiter: CheckedContinuation<Void, Error>?
    private var scanWaiter: CheckedContinuation<CBPeripheral, Error>?
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var servicesWaiter: CheckedContinuation<Void, Error>?
    private var characteristicWaiter: CheckedContinuation<Void, Error>?
    private var notifyWaiter: CheckedContinuation<Void, Error>?
    private var writeWaiter: (token: UUID, continuation: CheckedContinuation<Void, Error>)?
    private var responseWaiter: (command: UInt8, token: UUID, continuation: CheckedContinuation<Packet, Error>)?

    private(set) var isConnected = false
    private var printInProgress = false

    init(emit: @escaping (NiimbotNativeEvent) -> Void) {
        self.emit = emit
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func print(dataURL: String) {
        guard !printInProgress else { return }
        printInProgress = true

        Task { @MainActor in
            var jobStarted = false
            var jobEnded = false
            do {
                emit(.progress("Buscando NIIMBOT B1 Pro…"))
                try await ensureConnected()

                let packed = try packImage(dataURL: dataURL)

                emit(.connected("B1 Pro conectada. Configurando impresión…"))
                _ = try await sendWait(0x21, bytes(density), response: 0x31, timeout: 2, step: "densidad")
                _ = try await sendWait(0x23, bytes(labelType), response: 0x33, timeout: 2, step: "tipo de etiqueta")

                _ = try await sendWait(
                    0x01,
                    bytes(0, 1, 0, 0, 0, 0, 0, speed, 0),
                    response: 0x02,
                    timeout: 3,
                    step: "inicio de impresión"
                )
                jobStarted = true

                try await send(0xA3, bytes(1))
                try await Task.sleep(nanoseconds: 30_000_000)

                let pageSize = bytes(
                    (height >> 8) & 0xff, height & 0xff,
                    (width >> 8) & 0xff, width & 0xff,
                    0, 1,
                    0, 0, 0, 0, 0, 0, 0
                )
                _ = try await sendWait(0x13, pageSize, response: 0x14, timeout: 3, step: "tamaño de página")

                emit(.progress("Enviando etiqueta a la B1 Pro…"))
                try await sendImage(packed)

                _ = try await sendWait(0xE3, bytes(1), response: 0xE4, timeout: 12, step: "fin de página")

                emit(.progress("Imprimiendo…"))
                try await waitUntilPrinted()

                _ = try await sendWait(0xF3, bytes(1), response: 0xF4, timeout: 4, step: "fin de trabajo")
                jobEnded = true
                emit(.success("Etiqueta impresa y confirmada por la B1 Pro."))
            } catch {
                if jobStarted && !jobEnded {
                    try? await sendWait(0xF3, bytes(1), response: 0xF4, timeout: 2.5, step: "fin de trabajo")
                }
                emit(.error(error.localizedDescription))
            }
            printInProgress = false
        }
    }

    func disconnect() {
        central.stopScan()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            clearConnectionState()
            emit(.disconnected("B1 Pro desconectada."))
        }
    }

    private func ensureConnected() async throws {
        if isConnected, peripheral?.state == .connected, characteristic != nil {
            return
        }

        try await waitForBluetooth()
        let selected = try await scanForPrinter()
        try await connect(to: selected)
        try await discoverPrinterChannel()

        try await writeRaw(bytes(0x03, 0x55, 0x55, 0xC1, 0x01, 0x01, 0xC1, 0xAA, 0xAA))
        try await Task.sleep(nanoseconds: 200_000_000)

        _ = try? await sendWait(0xA5, bytes(1), response: 0xB5, timeout: 1.5, step: "versión de protocolo")
        let model = try await sendWait(0x40, bytes(0x08), response: 0x48, timeout: 2, step: "identificación")

        let id: Int
        if model.data.count >= 2 {
            id = (Int(model.data[0]) << 8) | Int(model.data[1])
        } else if model.data.count == 1 {
            id = Int(model.data[0]) << 8
        } else {
            id = 0
        }

        guard id == modelIDB1Pro else {
            disconnect()
            throw PrinterError.wrongPrinter(id)
        }

        isConnected = true
    }

    private func waitForBluetooth() async throws {
        if central.state == .poweredOn { return }
        if central.state == .unsupported || central.state == .unauthorized || central.state == .poweredOff {
            throw PrinterError.bluetoothUnavailable
        }

        try await withCheckedThrowingContinuation { continuation in
            powerWaiter = continuation
        }
    }

    private func scanForPrinter() async throws -> CBPeripheral {
        candidates.removeAll()
        central.stopScan()

        return try await withCheckedThrowingContinuation { continuation in
            scanWaiter = continuation
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self, let waiter = self.scanWaiter else { return }
                self.scanWaiter = nil
                self.central.stopScan()

                if let best = self.candidates.values.max(by: { $0.rssi < $1.rssi }) {
                    waiter.resume(returning: best.peripheral)
                } else {
                    waiter.resume(throwing: PrinterError.printerNotFound)
                }
            }
        }
    }

    private func connect(to device: CBPeripheral) async throws {
        if device.state == .connected {
            peripheral = device
            device.delegate = self
            return
        }

        peripheral = device
        device.delegate = self
        try await withCheckedThrowingContinuation { continuation in
            connectWaiter = continuation
            central.connect(device, options: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, let waiter = self.connectWaiter else { return }
                self.connectWaiter = nil
                waiter.resume(throwing: PrinterError.connectionFailed)
            }
        }
    }

    private func discoverPrinterChannel() async throws {
        guard let peripheral else { throw PrinterError.connectionFailed }

        try await withCheckedThrowingContinuation { continuation in
            servicesWaiter = continuation
            peripheral.discoverServices([serviceUUID])
        }

        guard peripheral.services?.first(where: { $0.uuid == serviceUUID }) != nil else {
            throw PrinterError.serviceMissing
        }

        let service = peripheral.services!.first(where: { $0.uuid == serviceUUID })!
        try await withCheckedThrowingContinuation { continuation in
            characteristicWaiter = continuation
            peripheral.discoverCharacteristics([characteristicUUID], for: service)
        }

        guard let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) else {
            throw PrinterError.characteristicMissing
        }
        self.characteristic = characteristic

        guard characteristic.properties.contains(.write) else {
            throw PrinterError.writeUnsupported
        }

        try await withCheckedThrowingContinuation { continuation in
            notifyWaiter = continuation
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    private func send(_ command: UInt8, _ data: Data) async throws {
        try await writeRaw(pack(command: command, data: data))
    }

    @discardableResult
    private func sendWait(
        _ command: UInt8,
        _ data: Data,
        response: UInt8,
        timeout: TimeInterval,
        step: String
    ) async throws -> Packet {
        try await send(command, data)
        return try await waitForResponse(response, timeout: timeout, step: step)
    }

    private func writeRaw(_ value: Data) async throws {
        guard let peripheral, let characteristic else { throw PrinterError.connectionFailed }
        guard characteristic.properties.contains(.write) else { throw PrinterError.writeUnsupported }
        guard value.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            throw PrinterError.writeUnsupported
        }

        try await withCheckedThrowingContinuation { continuation in
            let token = UUID()
            writeWaiter = (token, continuation)
            peripheral.writeValue(value, for: characteristic, type: .withResponse)

            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self,
                      let waiter = self.writeWaiter,
                      waiter.token == token else { return }
                self.writeWaiter = nil
                waiter.continuation.resume(throwing: PrinterError.writeTimeout)
            }
        }
    }

    private func waitForResponse(_ command: UInt8, timeout: TimeInterval, step: String) async throws -> Packet {
        if let index = bufferedPackets.firstIndex(where: { $0.command == command }) {
            return bufferedPackets.remove(at: index)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let token = UUID()
            responseWaiter = (command, token, continuation)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self,
                      let waiter = self.responseWaiter,
                      waiter.token == token else { return }
                self.responseWaiter = nil
                waiter.continuation.resume(throwing: PrinterError.responseTimeout(step))
            }
        }
    }

    private func sendImage(_ packed: Data) async throws {
        let stride = (width + 7) >> 3
        var row = 0
        var lastProgress = -10

        while row < height {
            let offset = row * stride
            let empty = rowIsEmpty(packed, offset: offset, stride: stride)
            var run = 1

            while row + run < height && run < 200 {
                let next = (row + run) * stride
                var same = true
                for index in 0..<stride where packed[offset + index] != packed[next + index] {
                    same = false
                    break
                }
                if !same { break }
                run += 1
            }

            if empty {
                try await send(0x84, bytes((row >> 8) & 0xff, row & 0xff, run))
            } else {
                let total = popcountRow(packed, offset: offset, stride: stride)
                var data = bytes(
                    (row >> 8) & 0xff,
                    row & 0xff,
                    0,
                    total & 0xff,
                    (total >> 8) & 0xff,
                    run
                )
                data.append(packed.subdata(in: offset..<(offset + stride)))
                try await send(0x85, data)
            }

            row += run
            let progress = row * 100 / height
            if progress >= lastProgress + 10 || row >= height {
                lastProgress = progress
                emit(.progress("Enviando etiqueta… \(progress)%"))
            }
        }
    }

    private func waitUntilPrinted() async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            do {
                let status = try await sendWait(0xA3, bytes(1), response: 0xB3, timeout: 1.5, step: "estado de impresión")
                if status.data.count >= 4 {
                    let page = (Int(status.data[0]) << 8) | Int(status.data[1])
                    let progress = Int(status.data[2])
                    emit(.progress("Imprimiendo… \(progress)%"))
                    if page >= 1 { return }
                }
            } catch PrinterError.responseTimeout(_) {
                // A status poll can legitimately miss one response; keep polling until the job deadline.
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw PrinterError.printUnconfirmed
    }

    private func packImage(dataURL: String) throws -> Data {
        guard let comma = dataURL.firstIndex(of: ","),
              dataURL.hasPrefix("data:image/png;base64,"),
              let sourceData = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let image = UIImage(data: sourceData),
              let cgImage = image.cgImage else {
            throw PrinterError.invalidImage
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgba = [UInt8](repeating: 255, count: height * bytesPerRow)

        // Important: CGContext must receive the backing bytes of the Swift array,
        // not the address of the Array value itself. Passing &rgba can corrupt
        // memory on a physical iPhone immediately after Bluetooth connects.
        let rendered = rgba.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }

            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .none
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard rendered else {
            throw PrinterError.invalidImage
        }

        let stride = (width + 7) >> 3
        var packed = Data(repeating: 0, count: stride * height)

        for y in 0..<height {
            for x in 0..<width {
                // Physical iPhone test: after correcting the horizontal mirror,
                // the label was readable but rotated 180 degrees. Relative to
                // that raster, the correct final orientation is obtained by
                // keeping X natural and reversing only the source Y row.
                let sourceY = height - 1 - y
                let i = sourceY * bytesPerRow + x * bytesPerPixel
                let red = Int(rgba[i])
                let green = Int(rgba[i + 1])
                let blue = Int(rgba[i + 2])
                let alpha = Int(rgba[i + 3])
                let luminance = (299 * red + 587 * green + 114 * blue) / 1000

                if alpha > 32 && luminance < 128 {
                    let index = y * stride + (x >> 3)
                    packed[index] |= UInt8(0x80 >> (x & 7))
                }
            }
        }

        return packed
    }

    private func pack(command: UInt8, data: Data) -> Data {
        var packet = Data([0x55, 0x55, command, UInt8(data.count)])
        var crc = command ^ UInt8(data.count)
        for value in data {
            packet.append(value)
            crc ^= value
        }
        packet.append(crc)
        packet.append(contentsOf: [0xAA, 0xAA])
        return packet
    }

    private func parseIncoming(_ value: Data) {
        receiveBuffer.append(value)

        while receiveBuffer.count >= 7 {
            // Data can keep a non-zero startIndex after removeFirst/removeSubrange.
            // Always calculate indexes from startIndex; numeric subscripts such as
            // receiveBuffer[0] can trap and terminate the app on real BLE traffic.
            let base = receiveBuffer.startIndex
            let second = receiveBuffer.index(base, offsetBy: 1)

            guard receiveBuffer[base] == 0x55, receiveBuffer[second] == 0x55 else {
                receiveBuffer.removeFirst()
                continue
            }

            let commandIndex = receiveBuffer.index(base, offsetBy: 2)
            let lengthIndex = receiveBuffer.index(base, offsetBy: 3)
            let length = Int(receiveBuffer[lengthIndex])
            let frameLength = 7 + length
            guard receiveBuffer.count >= frameLength else { return }

            let command = receiveBuffer[commandIndex]
            let dataStart = receiveBuffer.index(base, offsetBy: 4)
            let dataEnd = receiveBuffer.index(dataStart, offsetBy: length)
            let frameEnd = receiveBuffer.index(base, offsetBy: frameLength)
            let payload = Array(receiveBuffer[dataStart..<dataEnd])

            receiveBuffer.removeSubrange(base..<frameEnd)
            let packet = Packet(command: command, data: payload)

            if let waiter = responseWaiter, waiter.command == command {
                responseWaiter = nil
                waiter.continuation.resume(returning: packet)
            } else {
                bufferedPackets.append(packet)
                if bufferedPackets.count > 40 {
                    bufferedPackets.removeFirst(bufferedPackets.count - 40)
                }
            }
        }
    }

    private func rowIsEmpty(_ data: Data, offset: Int, stride: Int) -> Bool {
        for index in 0..<stride where data[offset + index] != 0 { return false }
        return true
    }

    private func popcountRow(_ data: Data, offset: Int, stride: Int) -> Int {
        var total = 0
        for index in 0..<stride {
            total += data[offset + index].nonzeroBitCount
        }
        return total
    }

    private func bytes(_ values: Int...) -> Data {
        Data(values.map { UInt8($0 & 0xff) })
    }

    private func clearConnectionState() {
        peripheral = nil
        characteristic = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        bufferedPackets.removeAll(keepingCapacity: true)
        isConnected = false
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let waiter = powerWaiter else { return }
        if central.state == .poweredOn {
            powerWaiter = nil
            waiter.resume()
        } else if central.state == .unsupported || central.state == .unauthorized || central.state == .poweredOff {
            powerWaiter = nil
            waiter.resume(throwing: PrinterError.bluetoothUnavailable)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name.uppercased().hasPrefix("B1") else { return }

        let candidate = Candidate(peripheral: peripheral, rssi: RSSI.intValue)
        if let existing = candidates[peripheral.identifier], existing.rssi >= candidate.rssi { return }
        candidates[peripheral.identifier] = candidate
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        if let waiter = connectWaiter {
            connectWaiter = nil
            waiter.resume()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        if let waiter = connectWaiter {
            connectWaiter = nil
            waiter.resume(throwing: error ?? PrinterError.connectionFailed)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        clearConnectionState()
        emit(.disconnected("La B1 Pro se desconectó. Volvé a conectar para imprimir."))
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let waiter = servicesWaiter else { return }
        servicesWaiter = nil
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let waiter = characteristicWaiter else { return }
        characteristicWaiter = nil
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == characteristicUUID, let waiter = notifyWaiter else { return }
        notifyWaiter = nil
        if let error {
            waiter.resume(throwing: error)
        } else if characteristic.isNotifying {
            waiter.resume()
        } else {
            waiter.resume(throwing: PrinterError.notificationsFailed)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == characteristicUUID, let waiter = writeWaiter else { return }
        writeWaiter = nil
        if let error {
            waiter.continuation.resume(throwing: error)
        } else {
            waiter.continuation.resume()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == characteristicUUID,
              error == nil,
              let value = characteristic.value else { return }
        parseIncoming(value)
    }
}
