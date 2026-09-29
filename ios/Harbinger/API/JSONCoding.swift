import Foundation

/// Parses a server timestamp. The Worker emits `toISOString()` (fractional seconds),
/// which `.iso8601` rejects; fall back to whole seconds.
nonisolated func parseTimestamp(_ string: String) -> Date? {
  let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  if let date = try? Date(string, strategy: fractional) {
    return date
  }
  return try? Date(string, strategy: Date.ISO8601FormatStyle())
}

/// The format style truncates to milliseconds, and a parsed `.456` is stored as `.4559999…`;
/// add half a millisecond so it rounds back to the server's value.
nonisolated func formatTimestamp(_ date: Date) -> String {
  date.addingTimeInterval(0.0005).formatted(
    Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

nonisolated func makeDecoder() -> JSONDecoder {
  let decoder = JSONDecoder()
  decoder.keyDecodingStrategy = .convertFromSnakeCase
  decoder.dateDecodingStrategy = .custom { decoder in
    let container = try decoder.singleValueContainer()
    let string = try container.decode(String.self)
    guard let date = parseTimestamp(string) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid ISO 8601 timestamp: \(string)")
    }
    return date
  }
  return decoder
}

nonisolated func makeEncoder() -> JSONEncoder {
  let encoder = JSONEncoder()
  encoder.keyEncodingStrategy = .convertToSnakeCase
  encoder.dateEncodingStrategy = .custom { date, encoder in
    var container = encoder.singleValueContainer()
    try container.encode(formatTimestamp(date))
  }
  return encoder
}
