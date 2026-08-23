//
//  CRC32.swift
//  Inkling
//
//  Shared ZIP checksum implementation for Word import and export.
//

import Foundation

enum CRC32 {
    nonisolated private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (0xedb8_8320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    nonisolated static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xffff_ffff
    }
}
