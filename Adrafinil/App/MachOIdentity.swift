import Foundation
import MachO

/// The UUID the linker stamps into a Mach-O image: the same for two copies
/// of one build, different for any two builds, whatever version they claim.
nonisolated enum MachOIdentity {
    /// The running process's own image, read from memory: a file at the
    /// executable's path can be a newer build than the process started from.
    static var ofThisProcess: String? {
        // The executable is whichever loaded image says it is one; its place
        // in dyld's list is no promise.
        for index in 0 ..< _dyld_image_count() {
            guard let header = _dyld_get_image_header(index), header.pointee.filetype == UInt32(MH_EXECUTE)
            else { continue }
            let commands = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
            return uuid(in: commands, count: Int(header.pointee.ncmds), limit: Int(header.pointee.sizeofcmds))
        }
        return nil
    }

    /// The image in a file, thin or universal; a universal file answers with
    /// the slice this Mac runs.
    static func ofFile(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return data.withUnsafeBytes { buffer -> String? in
            guard let base = buffer.baseAddress, buffer.count >= MemoryLayout<mach_header_64>.size else { return nil }
            guard let offset = sliceOffset(base, size: buffer.count),
                  offset <= buffer.count - MemoryLayout<mach_header_64>.size else { return nil }
            let header = (base + offset).loadUnaligned(as: mach_header_64.self)
            guard header.magic == MH_MAGIC_64,
                  offset + MemoryLayout<mach_header_64>.size + Int(header.sizeofcmds) <= buffer.count else { return nil }
            return uuid(
                in: base + offset + MemoryLayout<mach_header_64>.size,
                count: Int(header.ncmds), limit: Int(header.sizeofcmds),
            )
        }
    }

    /// Where the 64-bit image starts: zero in a thin file, the matching
    /// architecture's offset in a universal one, whose table is big-endian.
    private static func sliceOffset(_ base: UnsafeRawPointer, size: Int) -> Int? {
        let magic = base.loadUnaligned(as: UInt32.self)
        if magic == MH_MAGIC_64 { return 0 }
        guard magic == FAT_CIGAM || magic == FAT_MAGIC else { return nil }
        let count = Int(UInt32(bigEndian: (base + 4).loadUnaligned(as: UInt32.self)))
        #if arch(arm64)
            let wanted = CPU_TYPE_ARM64
        #else
            let wanted = CPU_TYPE_X86_64
        #endif
        for index in 0 ..< count {
            let entry = base + 8 + index * MemoryLayout<fat_arch>.size
            guard 8 + (index + 1) * MemoryLayout<fat_arch>.size <= size else { return nil }
            let type = Int32(bigEndian: entry.loadUnaligned(as: Int32.self))
            if type == wanted {
                return Int(UInt32(bigEndian: (entry + 8).loadUnaligned(as: UInt32.self)))
            }
        }
        return nil
    }

    private static func uuid(in commands: UnsafeRawPointer, count: Int, limit: Int) -> String? {
        var cursor = commands
        var consumed = 0
        for _ in 0 ..< count {
            guard consumed + MemoryLayout<load_command>.size <= limit else { return nil }
            let command = cursor.loadUnaligned(as: load_command.self)
            if command.cmd == UInt32(LC_UUID) {
                guard consumed + MemoryLayout<uuid_command>.size <= limit else { return nil }
                let bytes = (cursor + MemoryLayout<load_command>.size).loadUnaligned(as: uuid_t.self)
                return UUID(uuid: bytes).uuidString
            }
            guard command.cmdsize >= MemoryLayout<load_command>.size else { return nil }
            cursor += Int(command.cmdsize)
            consumed += Int(command.cmdsize)
        }
        return nil
    }
}
