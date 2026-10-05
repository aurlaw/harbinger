import SwiftUI
import UIKit

// The pick detail screen's background: the poster's dominant color, adjusted until the
// screen's text is readable on it. The color math is pure so it can be tested.

/// An sRGB color, components `0...1`.
nonisolated struct RGB: Equatable, Sendable {
  var red: Double
  var green: Double
  var blue: Double

  static let white = RGB(red: 1, green: 1, blue: 1)
  static let black = RGB(red: 0, green: 0, blue: 0)

  /// WCAG relative luminance, `0` (black) to `1` (white).
  var luminance: Double {
    func linear(_ value: Double) -> Double {
      value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  /// WCAG contrast ratio, `1` (same) to `21` (black on white).
  func contrast(with other: RGB) -> Double {
    let (lighter, darker) = (max(luminance, other.luminance), min(luminance, other.luminance))
    return (lighter + 0.05) / (darker + 0.05)
  }

  /// This color moved `amount` (`0...1`) of the way to `other`.
  func mixed(with other: RGB, _ amount: Double) -> RGB {
    RGB(
      red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
      blue: blue + (other.blue - blue) * amount)
  }
}

extension Color {
  nonisolated init(_ rgb: RGB) {
    self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
  }
}

/// The most common color in RGBA8 pixels: they are grouped into coarse buckets (3 bits per
/// channel), and the fullest bucket's average is the answer — so a poster that is mostly
/// orange gives its orange, not a muddy average of everything. Mostly transparent pixels
/// are skipped. `nil` when there is nothing to count.
nonisolated func dominantColor(rgba pixels: [UInt8]) -> RGB? {
  struct Bucket {
    var count = 0
    var red = 0
    var green = 0
    var blue = 0
  }
  var buckets = [Bucket](repeating: Bucket(), count: 512)
  for offset in stride(from: 0, to: pixels.count - 3, by: 4) where pixels[offset + 3] >= 128 {
    let (red, green, blue) = (
      Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])
    )
    let index = (red >> 5) << 6 | (green >> 5) << 3 | (blue >> 5)
    buckets[index].count += 1
    buckets[index].red += red
    buckets[index].green += green
    buckets[index].blue += blue
  }
  // The first of equally full buckets, so the answer never depends on iteration luck.
  guard
    let fullest = buckets.enumerated().max(by: { a, b in
      a.element.count == b.element.count ? a.offset > b.offset : a.element.count < b.element.count
    })?.element, fullest.count > 0
  else { return nil }
  let total = Double(fullest.count) * 255
  return RGB(
    red: Double(fullest.red) / total, green: Double(fullest.green) / total,
    blue: Double(fullest.blue) / total)
}

/// A background for the detail screen and the text it needs.
nonisolated struct DetailPalette: Equatable, Sendable {
  /// Body text must reach WCAG AAA on the background, and secondary text AA.
  static let minimumPrimaryContrast = 7.0
  static let minimumSecondaryContrast = 4.5

  let background: RGB
  /// Light text (the dark appearance's colors) rather than dark text.
  let usesLightText: Bool

  /// The dominant color itself when text is already readable on it; otherwise the same hue
  /// darkened (under light text) or lightened (under dark text) just far enough.
  init(dominant: RGB) {
    // Whichever text color starts out more readable needs the smaller change.
    let usesLightText = dominant.contrast(with: .white) >= dominant.contrast(with: .black)
    var background = dominant
    var step = 0
    while !Self.isReadable(on: background, lightText: usesLightText), step < 100 {
      step += 1
      background = dominant.mixed(with: usesLightText ? .black : .white, Double(step) / 100)
    }
    self.background = background
    self.usesLightText = usesLightText
  }

  var colorScheme: ColorScheme { usesLightText ? .dark : .light }

  static func primaryText(light: Bool) -> RGB {
    light ? .white : .black
  }

  /// Secondary text on this screen is the text color at this opacity. (The system's own
  /// secondary label is too faint to reach AA on a light background, whatever its color.)
  static let secondaryOpacity = 0.75

  /// Secondary text as it lands on `background`.
  static func secondaryText(on background: RGB, light: Bool) -> RGB {
    background.mixed(with: primaryText(light: light), secondaryOpacity)
  }

  static func isReadable(on background: RGB, lightText: Bool) -> Bool {
    background.contrast(with: primaryText(light: lightText)) >= minimumPrimaryContrast
      && background.contrast(with: secondaryText(on: background, light: lightText))
        >= minimumSecondaryContrast
  }
}

/// The palette for encoded image data (JPEG / PNG); `nil` if it isn't an image.
nonisolated func posterPalette(from data: Data) -> DetailPalette? {
  guard let image = UIImage(data: data)?.cgImage else { return nil }
  // A thumbnail is plenty for a dominant color, and keeps this cheap.
  let (width, height) = (24, 36)
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
  }
  guard drawn, let dominant = dominantColor(rgba: pixels) else { return nil }
  return DetailPalette(dominant: dominant)
}

/// Fetches the poster (the card size, which the chat has usually cached already) and works
/// out its palette off the main actor. `nil` for a missing poster or any failure — the
/// screen then keeps the system background.
@concurrent
nonisolated func loadPosterPalette(path: String?, session: URLSession = .shared) async
  -> DetailPalette?
{
  guard let url = tmdbImageURL(path: path, size: .w185),
    let (data, _) = try? await session.data(from: url)
  else { return nil }
  return posterPalette(from: data)
}
