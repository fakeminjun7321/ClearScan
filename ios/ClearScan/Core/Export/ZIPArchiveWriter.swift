import Foundation

struct ZIPArchiveEntry: Equatable {
  let path: String
  let data: Data
  let modificationDate: Date
}

enum ZIPArchiveWriterError: Error, Equatable {
  case emptyArchive
  case invalidEntryPath(String)
  case tooManyEntries
  case entryTooLarge(String)
  case archiveTooLarge
}

/// Writes a standards-compliant ZIP archive using the "stored" method.
/// Avoiding compression keeps the implementation dependency-free and is a
/// good fit for JPEG input, which is already compressed.
struct ZIPArchiveWriter {
  func archive(entries: [ZIPArchiveEntry]) throws -> Data {
    guard !entries.isEmpty else { throw ZIPArchiveWriterError.emptyArchive }
    guard entries.count <= Int(UInt16.max) else {
      throw ZIPArchiveWriterError.tooManyEntries
    }

    var output = Data()
    var centralDirectory = Data()

    for entry in entries {
      try validate(path: entry.path)
      guard entry.data.count <= Int(UInt32.max) else {
        throw ZIPArchiveWriterError.entryTooLarge(entry.path)
      }
      guard output.count <= Int(UInt32.max) else {
        throw ZIPArchiveWriterError.archiveTooLarge
      }

      let fileName = Data(entry.path.utf8)
      guard fileName.count <= Int(UInt16.max) else {
        throw ZIPArchiveWriterError.invalidEntryPath(entry.path)
      }
      let crc = CRC32.checksum(entry.data)
      let size = UInt32(entry.data.count)
      let localHeaderOffset = UInt32(output.count)
      let (dosTime, dosDate) = Self.dosTimestamp(for: entry.modificationDate)

      output.appendUInt32LE(0x0403_4b50)
      output.appendUInt16LE(20)
      output.appendUInt16LE(0x0800)
      output.appendUInt16LE(0)
      output.appendUInt16LE(dosTime)
      output.appendUInt16LE(dosDate)
      output.appendUInt32LE(crc)
      output.appendUInt32LE(size)
      output.appendUInt32LE(size)
      output.appendUInt16LE(UInt16(fileName.count))
      output.appendUInt16LE(0)
      output.append(fileName)
      output.append(entry.data)

      centralDirectory.appendUInt32LE(0x0201_4b50)
      centralDirectory.appendUInt16LE(20)
      centralDirectory.appendUInt16LE(20)
      centralDirectory.appendUInt16LE(0x0800)
      centralDirectory.appendUInt16LE(0)
      centralDirectory.appendUInt16LE(dosTime)
      centralDirectory.appendUInt16LE(dosDate)
      centralDirectory.appendUInt32LE(crc)
      centralDirectory.appendUInt32LE(size)
      centralDirectory.appendUInt32LE(size)
      centralDirectory.appendUInt16LE(UInt16(fileName.count))
      centralDirectory.appendUInt16LE(0)
      centralDirectory.appendUInt16LE(0)
      centralDirectory.appendUInt16LE(0)
      centralDirectory.appendUInt16LE(0)
      centralDirectory.appendUInt32LE(0)
      centralDirectory.appendUInt32LE(localHeaderOffset)
      centralDirectory.append(fileName)
    }

    guard output.count <= Int(UInt32.max),
      centralDirectory.count <= Int(UInt32.max),
      output.count + centralDirectory.count <= Int(UInt32.max)
    else {
      throw ZIPArchiveWriterError.archiveTooLarge
    }

    let centralDirectoryOffset = UInt32(output.count)
    output.append(centralDirectory)
    output.appendUInt32LE(0x0605_4b50)
    output.appendUInt16LE(0)
    output.appendUInt16LE(0)
    output.appendUInt16LE(UInt16(entries.count))
    output.appendUInt16LE(UInt16(entries.count))
    output.appendUInt32LE(UInt32(centralDirectory.count))
    output.appendUInt32LE(centralDirectoryOffset)
    output.appendUInt16LE(0)
    return output
  }

  private func validate(path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty,
      !path.hasPrefix("/"),
      !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    else {
      throw ZIPArchiveWriterError.invalidEntryPath(path)
    }
  }

  private static func dosTimestamp(for date: Date) -> (UInt16, UInt16) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: date
    )
    let year = min(max(components.year ?? 1980, 1980), 2107)
    let month = min(max(components.month ?? 1, 1), 12)
    let day = min(max(components.day ?? 1, 1), 31)
    let hour = min(max(components.hour ?? 0, 0), 23)
    let minute = min(max(components.minute ?? 0, 0), 59)
    let second = min(max(components.second ?? 0, 0), 59)

    let time = UInt16((hour << 11) | (minute << 5) | (second / 2))
    let date = UInt16(((year - 1980) << 9) | (month << 5) | day)
    return (time, date)
  }
}

private enum CRC32 {
  static func checksum(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
      let index = Int((crc ^ UInt32(byte)) & 0xff)
      crc = table[index] ^ (crc >> 8)
    }
    return crc ^ 0xffff_ffff
  }

  private static let table: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 {
      crc =
        (crc & 1) == 1
        ? 0xedb8_8320 ^ (crc >> 1)
        : crc >> 1
    }
    return crc
  }
}

extension Data {
  fileprivate mutating func appendUInt16LE(_ value: UInt16) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { bytes in
      append(contentsOf: bytes)
    }
  }

  fileprivate mutating func appendUInt32LE(_ value: UInt32) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { bytes in
      append(contentsOf: bytes)
    }
  }
}
