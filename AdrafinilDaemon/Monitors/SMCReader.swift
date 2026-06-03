import Foundation
import IOKit

/// Minimal SMC client. Reads a single sensor key as Float (sp78/flt formats).
///
/// Based on the publicly documented AppleSMC interface used by stats apps for years.
/// No private headers; no entitlements required.
final class SMCReader: @unchecked Sendable {
    private var connection: io_connect_t = 0
    private var isOpen: Bool {
        connection != 0
    }

    deinit { close() }

    func open() -> Bool {
        guard !isOpen else { return true }
        let matching = IOServiceMatching("AppleSMC")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        return result == kIOReturnSuccess
    }

    func close() {
        if isOpen {
            IOServiceClose(connection)
            connection = 0
        }
    }

    /// Reads a four-character SMC key (e.g. "TC0P") as a Double in degrees C.
    func readTemperature(key: String) -> Double? {
        guard open() else { return nil }
        guard key.count == 4 else { return nil }

        var input = SMCKeyData()
        var output = SMCKeyData()

        input.key = fourCharCode(from: key)
        input.data8 = 9 // kSMCGetKeyInfo
        if !call(selector: 2, input: &input, output: &output) { return nil }

        let dataSize = output.keyInfo.dataSize
        let dataTypeRaw = output.keyInfo.dataType
        input.keyInfo.dataSize = dataSize
        input.data8 = 5 // kSMCReadKey

        if !call(selector: 2, input: &input, output: &output) { return nil }

        let dataType = decodeFourCC(dataTypeRaw)
        return decodeTemperature(bytes: output.bytes, size: dataSize, type: dataType)
    }

    // MARK: - low level

    private func call(selector: UInt32, input: inout SMCKeyData, output: inout SMCKeyData) -> Bool {
        var outputSize = MemoryLayout<SMCKeyData>.size
        let inputSize = MemoryLayout<SMCKeyData>.size
        let result = IOConnectCallStructMethod(connection, selector, &input, inputSize, &output, &outputSize)
        return result == kIOReturnSuccess
    }

    private func fourCharCode(from s: String) -> UInt32 {
        let bytes = Array(s.utf8)
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    private func decodeFourCC(_ value: UInt32) -> String {
        let b0 = UInt8((value >> 24) & 0xFF)
        let b1 = UInt8((value >> 16) & 0xFF)
        let b2 = UInt8((value >> 8) & 0xFF)
        let b3 = UInt8(value & 0xFF)
        return String(bytes: [b0, b1, b2, b3], encoding: .ascii) ?? ""
    }

    private func decodeTemperature(bytes: SMCBytes, size _: UInt32, type: String) -> Double? {
        // We only need to handle the temperature formats: "sp78" (Intel) and "flt " (Apple Silicon).
        let b0 = bytes.0, b1 = bytes.1, b2 = bytes.2, b3 = bytes.3
        switch type {
        case "sp78":
            // 16-bit signed fixed-point, 8 integer + 8 fraction bits.
            let raw = Int16(bitPattern: (UInt16(b0) << 8) | UInt16(b1))
            return Double(raw) / 256.0
        case "flt ":
            // IEEE 754 float, little-endian.
            var value: Float = 0
            withUnsafeMutableBytes(of: &value) {
                $0[0] = b0; $0[1] = b1; $0[2] = b2; $0[3] = b3
            }
            return Double(value)
        default:
            return nil
        }
    }
}

// MARK: - SMC structs

private typealias SMCBytes = (
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
    UInt8,
)

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers: (UInt8, UInt8, UInt8, UInt8, UInt32) = (0, 0, 0, 0, 0)
    var pLimitData: (UInt16, UInt16, UInt16, UInt16, UInt32) = (0, 0, 0, 0, 0)
    var keyInfo: SMCKeyInfoData = .init()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    )
}
