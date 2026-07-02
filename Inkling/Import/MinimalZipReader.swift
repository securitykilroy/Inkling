//
//  MinimalZipReader.swift
//  Inkling
//
//  A from-scratch ZIP reader, because a .docx is a ZIP archive and Inkling is
//  sandboxed — it cannot shell out to /usr/bin/unzip. Reads the central
//  directory (no Zip64 support; .docx files never need it) and decompresses
//  entries via the Compression framework, which decodes ZIP's raw DEFLATE
//  streams despite the COMPRESSION_ZLIB name (verified against a real Word
//  file: byte-for-byte match with unzip's own output).
//

import Compression
import Foundation

struct MinimalZipReader {

    enum ZipReaderError: Error, Equatable {
        case notAZipArchive
        case entryNotFound(String)
        case unsupportedCompressionMethod(UInt16)
        case corruptEntry(String)
    }

    private struct Entry {
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

        switch entry.compressionMethod {
        case 0:
            return Data(compressed)
        case 8:
            return try Self.inflate(compressed, uncompressedSize: entry.uncompressedSize, name: name)
        default:
            throw ZipReaderError.unsupportedCompressionMethod(entry.compressionMethod)
        }
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ bytes: [UInt8]) throws -> [String: Entry] {
        guard let eocdOffset = findEndOfCentralDirectory(bytes) else {
            throw ZipReaderError.notAZipArchive
        }
        guard let recordCount = readUInt16LE(bytes, at: eocdOffset + 10),
              let centralDirectoryOffset = readUInt32LE(bytes, at: eocdOffset + 16)
        else {
            throw ZipReaderError.notAZipArchive
        }

        var entries: [String: Entry] = [:]
        var offset = Int(centralDirectoryOffset)
        for _ in 0..<recordCount {
            guard let signature = readUInt32LE(bytes, at: offset), signature == 0x0201_4b50,
                  let method = readUInt16LE(bytes, at: offset + 10),
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

            entries[name] = Entry(
                compressionMethod: method,
                compressedSize: Int(compressedSize),
                uncompressedSize: Int(uncompressedSize),
                localHeaderOffset: Int(localHeaderOffset)
            )

            offset = nameStart + Int(nameLength) + Int(extraLength) + Int(commentLength)
        }
        return entries
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
}
