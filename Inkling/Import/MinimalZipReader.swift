//
//  MinimalZipReader.swift
//  Inkling
//
//  A from-scratch ZIP reader, because a .docx is a ZIP archive and Inkling is
//  sandboxed — it cannot shell out to /usr/bin/unzip. Reads the central
//  directory and decompresses entries via the Compression framework, which
//  decodes ZIP's raw DEFLATE streams despite the COMPRESSION_ZLIB name
//  (verified against a real Word file: byte-for-byte match with unzip's own
//  output).
//
//  Zip64 is supported, in both the "too many entries / directory too far in"
//  form (a Zip64 end-of-central-directory record) and the per-entry form (a
//  0xFFFFFFFF placeholder in the central directory with the real value in the
//  entry's Zip64 extra field). Word itself never needs it, but Google Docs and
//  LibreOffice emit it for ordinary documents, and without it those failed the
//  import with a bare "isn't a valid Word document (.docx)".
//
//  Entries written with a streaming data descriptor need no special handling:
//  the sizes here are always read from the central directory, which is
//  authoritative, never from the local header's (possibly zeroed) copy.
//

import Compression
import Foundation

struct MinimalZipReader {

    /// A Word package can legitimately contain large images, but no individual
    /// part should be able to make the importer reserve gigabytes based only on
    /// an untrusted central-directory field.
    private static let maximumEntrySize = 256 * 1_024 * 1_024
    private static let maximumArchiveSize = 512 * 1_024 * 1_024

    enum ZipReaderError: Error, Equatable {
        case notAZipArchive
        case entryNotFound(String)
        case unsupportedCompressionMethod(UInt16)
        case corruptEntry(String)
    }

    private struct Entry {
        let checksum: UInt32
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let bytes: [UInt8]
    private let entries: [String: Entry]

    var names: [String] { Array(entries.keys) }

    init(data: Data) throws {
        self.bytes = [UInt8](data)
        self.entries = try Self.readCentralDirectory(bytes)
    }

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    func contents(of name: String) throws -> Data {
        guard let entry = entries[name] else {
            throw ZipReaderError.entryNotFound(name)
        }

        // The central directory's sizes are authoritative, but the actual
        // compressed data starts after the *local* file header, whose
        // filename/extra-field lengths can differ from the central
        // directory's copy — so that header must be read too.
        guard let local = Self.readUInt32LE(bytes, at: entry.localHeaderOffset),
              local == 0x0403_4b50,
              let nameLength = Self.readUInt16LE(bytes, at: entry.localHeaderOffset + 26),
              let extraLength = Self.readUInt16LE(bytes, at: entry.localHeaderOffset + 28)
        else {
            throw ZipReaderError.corruptEntry(name)
        }

        let dataStart = entry.localHeaderOffset + 30 + Int(nameLength) + Int(extraLength)
        guard dataStart + entry.compressedSize <= bytes.count else {
            throw ZipReaderError.corruptEntry(name)
        }
        let compressed = Array(bytes[dataStart..<(dataStart + entry.compressedSize)])

        let result: Data
        switch entry.compressionMethod {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else {
                throw ZipReaderError.corruptEntry(name)
            }
            result = Data(compressed)
        case 8:
            result = try Self.inflate(compressed, uncompressedSize: entry.uncompressedSize, name: name)
        default:
            throw ZipReaderError.unsupportedCompressionMethod(entry.compressionMethod)
        }
        guard CRC32.checksum(result) == entry.checksum else {
            throw ZipReaderError.corruptEntry(name)
        }
        return result
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ bytes: [UInt8]) throws -> [String: Entry] {
        guard let eocdOffset = findEndOfCentralDirectory(bytes) else {
            throw ZipReaderError.notAZipArchive
        }
        guard var recordCount = readUInt16LE(bytes, at: eocdOffset + 10).map(Int.init),
              var centralDirectoryOffset = readUInt32LE(bytes, at: eocdOffset + 16).map(Int.init)
        else {
            throw ZipReaderError.notAZipArchive
        }

        // Either field saturated means the real value lives in the Zip64
        // end-of-central-directory record instead.
        if recordCount == 0xFFFF || centralDirectoryOffset == 0xFFFF_FFFF {
            guard let zip64 = readZip64EndOfCentralDirectory(bytes, eocdOffset: eocdOffset) else {
                throw ZipReaderError.notAZipArchive
            }
            recordCount = zip64.recordCount
            centralDirectoryOffset = zip64.centralDirectoryOffset
        }

        var entries: [String: Entry] = [:]
        var totalUncompressedSize = 0
        var offset = centralDirectoryOffset
        for _ in 0..<recordCount {
            guard let signature = readUInt32LE(bytes, at: offset), signature == 0x0201_4b50,
                  let method = readUInt16LE(bytes, at: offset + 10),
                  let checksum = readUInt32LE(bytes, at: offset + 16),
                  let compressedSize = readUInt32LE(bytes, at: offset + 20),
                  let uncompressedSize = readUInt32LE(bytes, at: offset + 24),
                  let nameLength = readUInt16LE(bytes, at: offset + 28),
                  let extraLength = readUInt16LE(bytes, at: offset + 30),
                  let commentLength = readUInt16LE(bytes, at: offset + 32),
                  let localHeaderOffset = readUInt32LE(bytes, at: offset + 42)
            else {
                throw ZipReaderError.notAZipArchive
            }

            let nameStart = offset + 46
            guard nameStart + Int(nameLength) <= bytes.count else {
                throw ZipReaderError.notAZipArchive
            }
            let name = String(decoding: bytes[nameStart..<(nameStart + Int(nameLength))], as: UTF8.self)

            let sizes = try zip64Sizes(
                bytes,
                extraStart: nameStart + Int(nameLength),
                extraLength: Int(extraLength),
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                name: name
            )

            guard sizes.uncompressedSize <= maximumEntrySize,
                  totalUncompressedSize <= maximumArchiveSize - sizes.uncompressedSize
            else {
                throw ZipReaderError.corruptEntry(name)
            }
            totalUncompressedSize += sizes.uncompressedSize

            entries[name] = Entry(
                checksum: checksum,
                compressionMethod: method,
                compressedSize: sizes.compressedSize,
                uncompressedSize: sizes.uncompressedSize,
                localHeaderOffset: sizes.localHeaderOffset
            )

            offset = nameStart + Int(nameLength) + Int(extraLength) + Int(commentLength)
        }
        return entries
    }

    /// The entry count and central-directory offset from the Zip64 EOCD record,
    /// found through the fixed-size locator that sits immediately before the
    /// ordinary EOCD.
    private static func readZip64EndOfCentralDirectory(
        _ bytes: [UInt8],
        eocdOffset: Int
    ) -> (recordCount: Int, centralDirectoryOffset: Int)? {
        let locator = eocdOffset - 20
        guard locator >= 0,
              readUInt32LE(bytes, at: locator) == 0x0706_4b50,
              let recordOffset = readUInt64LE(bytes, at: locator + 8).flatMap(safeInt),
              readUInt32LE(bytes, at: recordOffset) == 0x0606_4b50,
              let count = readUInt64LE(bytes, at: recordOffset + 32).flatMap(safeInt),
              let directoryOffset = readUInt64LE(bytes, at: recordOffset + 48).flatMap(safeInt)
        else { return nil }
        return (count, directoryOffset)
    }

    /// Resolves the three central-directory fields that Zip64 can displace. A
    /// 0xFFFFFFFF placeholder means the real 8-byte value is in the entry's
    /// Zip64 extended information extra field (header ID 0x0001), where the
    /// present fields appear in a fixed order and only the displaced ones are
    /// written at all.
    private static func zip64Sizes(
        _ bytes: [UInt8],
        extraStart: Int,
        extraLength: Int,
        compressedSize: UInt32,
        uncompressedSize: UInt32,
        localHeaderOffset: UInt32,
        name: String
    ) throws -> (compressedSize: Int, uncompressedSize: Int, localHeaderOffset: Int) {
        let placeholder: UInt32 = 0xFFFF_FFFF
        guard compressedSize == placeholder
                || uncompressedSize == placeholder
                || localHeaderOffset == placeholder
        else {
            return (Int(compressedSize), Int(uncompressedSize), Int(localHeaderOffset))
        }

        guard let field = zip64ExtraField(bytes, start: extraStart, length: extraLength) else {
            throw ZipReaderError.corruptEntry(name)
        }

        var cursor = field
        func next() throws -> Int {
            guard let value = readUInt64LE(bytes, at: cursor).flatMap(safeInt) else {
                throw ZipReaderError.corruptEntry(name)
            }
            cursor += 8
            return value
        }

        // Order is fixed by the spec: uncompressed, compressed, local header
        // offset, disk number — each present only when its 32-bit field was
        // saturated, so they must be read in that order and skipped otherwise.
        let expanded = uncompressedSize == placeholder ? try next() : Int(uncompressedSize)
        let stored = compressedSize == placeholder ? try next() : Int(compressedSize)
        let header = localHeaderOffset == placeholder ? try next() : Int(localHeaderOffset)
        return (stored, expanded, header)
    }

    /// Start offset of the Zip64 extended information field's payload within an
    /// entry's extra-field block, walking the block's header-ID/size pairs.
    private static func zip64ExtraField(_ bytes: [UInt8], start: Int, length: Int) -> Int? {
        guard length > 0, start >= 0, start + length <= bytes.count else { return nil }
        var offset = start
        let end = start + length
        while offset + 4 <= end {
            guard let headerID = readUInt16LE(bytes, at: offset),
                  let size = readUInt16LE(bytes, at: offset + 2)
            else { return nil }
            let payload = offset + 4
            guard payload + Int(size) <= end else { return nil }
            if headerID == 0x0001 { return payload }
            offset = payload + Int(size)
        }
        return nil
    }

    /// A 64-bit ZIP field narrowed to `Int`, rejecting anything that couldn't
    /// address this archive anyway. Keeps a hostile value from wrapping.
    private static func safeInt(_ value: UInt64) -> Int? {
        value <= UInt64(Int.max) ? Int(value) : nil
    }

    /// Scans backward from the end of the file for the End Of Central
    /// Directory signature. The EOCD record is fixed-size (22 bytes) plus an
    /// optional trailing comment (max 65535 bytes), so it always lives within
    /// the last ~64KB of a well-formed archive.
    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let searchStart = max(0, bytes.count - 22 - 65535)
        var offset = bytes.count - 22
        while offset >= searchStart {
            if let signature = readUInt32LE(bytes, at: offset), signature == 0x0605_4b50 {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    // MARK: - Decompression

    private static func inflate(_ compressed: [UInt8], uncompressedSize: Int, name: String) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        var destination = [UInt8](repeating: 0, count: uncompressedSize)

        let decodedCount = compressed.withUnsafeBufferPointer { source -> Int in
            destination.withUnsafeMutableBufferPointer { dest -> Int in
                guard let sourceBase = source.baseAddress, let destBase = dest.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destBase, uncompressedSize, sourceBase, compressed.count, nil, COMPRESSION_ZLIB
                )
            }
        }

        guard decodedCount == uncompressedSize else {
            throw ZipReaderError.corruptEntry(name)
        }
        return Data(destination)
    }

    // MARK: - Little-endian reads

    private static func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readUInt64LE(_ bytes: [UInt8], at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= bytes.count else { return nil }
        var value: UInt64 = 0
        for index in (0..<8).reversed() {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        return value
    }
}
