import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Harbinger

// The pick detail background: the poster's dominant color, made readable.

struct PosterPaletteTests {
  /// RGBA8 pixels: `count` of each color.
  func pixels(_ runs: [(color: (UInt8, UInt8, UInt8), alpha: UInt8, count: Int)]) -> [UInt8] {
    runs.flatMap { run in
      (0..<run.count).flatMap { _ in [run.color.0, run.color.1, run.color.2, run.alpha] }
    }
  }

  func close(_ a: RGB, _ b: RGB, within tolerance: Double = 0.02) -> Bool {
    abs(a.red - b.red) <= tolerance && abs(a.green - b.green) <= tolerance
      && abs(a.blue - b.blue) <= tolerance
  }

  // MARK: - Contrast math

  @Test func luminanceAndContrast() {
    #expect(RGB.white.luminance == 1)
    #expect(RGB.black.luminance == 0)
    #expect(abs(RGB.white.contrast(with: .black) - 21) < 0.0001)
    #expect(RGB.white.contrast(with: .white) == 1)
    let gray = RGB(red: 0.5, green: 0.5, blue: 0.5)
    #expect(gray.contrast(with: .black) == RGB.black.contrast(with: gray))
    // #767676 on white is the well-known 4.54:1.
    let reference = RGB(red: 118 / 255, green: 118 / 255, blue: 118 / 255)
    #expect(abs(reference.contrast(with: .white) - 4.54) < 0.01)
  }

  @Test func mixing() {
    let red = RGB(red: 1, green: 0, blue: 0)
    #expect(red.mixed(with: .black, 0) == red)
    #expect(red.mixed(with: .black, 1) == .black)
    #expect(red.mixed(with: .white, 0.5) == RGB(red: 1, green: 0.5, blue: 0.5))
  }

  // MARK: - Dominant color

  @Test func theMostCommonColorWinsNotTheAverage() throws {
    let orange: (UInt8, UInt8, UInt8) = (200, 80, 20)
    let color = try #require(
      dominantColor(
        rgba: pixels([
          (orange, 255, 60), ((10, 10, 10), 255, 25), ((240, 230, 200), 255, 15),
        ])))

    #expect(close(color, RGB(red: 200 / 255, green: 80 / 255, blue: 20 / 255)))
  }

  @Test func nearbyShadesCountTogetherAndAverage() throws {
    // Two oranges in one bucket outvote a single larger run of blue.
    let color = try #require(
      dominantColor(
        rgba: pixels([
          ((200, 80, 20), 255, 30), ((210, 90, 30), 255, 30), ((20, 40, 200), 255, 40),
        ])))

    #expect(close(color, RGB(red: 205 / 255, green: 85 / 255, blue: 25 / 255)))
  }

  @Test func transparentPixelsAreIgnored() throws {
    let color = try #require(
      dominantColor(rgba: pixels([((255, 0, 0), 0, 90), ((0, 0, 255), 255, 10)])))

    #expect(close(color, RGB(red: 0, green: 0, blue: 1)))
  }

  @Test func nothingToCountIsNil() {
    #expect(dominantColor(rgba: []) == nil)
    #expect(dominantColor(rgba: pixels([((255, 0, 0), 0, 10)])) == nil)
    #expect(dominantColor(rgba: [1, 2, 3]) == nil)
  }

  @Test func tiesAreStable() {
    let a = pixels([((200, 80, 20), 255, 10), ((20, 40, 200), 255, 10)])
    let b = pixels([((20, 40, 200), 255, 10), ((200, 80, 20), 255, 10)])

    #expect(dominantColor(rgba: a) == dominantColor(rgba: b))
  }

  // MARK: - Readable palette

  /// Every color on a coarse grid of the whole RGB cube ends up readable.
  @Test func everyColorGetsReadableText() {
    let steps = stride(from: 0.0, through: 1.0, by: 0.125)
    for red in steps {
      for green in steps {
        for blue in steps {
          let palette = DetailPalette(dominant: RGB(red: red, green: green, blue: blue))
          let primary = DetailPalette.primaryText(light: palette.usesLightText)
          let secondary = DetailPalette.secondaryText(
            on: palette.background, light: palette.usesLightText)

          #expect(palette.background.contrast(with: primary) >= 7)
          #expect(palette.background.contrast(with: secondary) >= 4.5)
        }
      }
    }
  }

  @Test func darkColorsGetLightTextAndLightColorsDarkText() {
    let navy = DetailPalette(dominant: RGB(red: 0.05, green: 0.08, blue: 0.3))
    #expect(navy.usesLightText)
    #expect(navy.colorScheme == .dark)

    let cream = DetailPalette(dominant: RGB(red: 0.96, green: 0.92, blue: 0.8))
    #expect(!cream.usesLightText)
    #expect(cream.colorScheme == .light)

    #expect(DetailPalette(dominant: .black).usesLightText)
    #expect(!DetailPalette(dominant: .white).usesLightText)
  }

  @Test func anAlreadyReadableColorIsKeptAsItIs() {
    let navy = RGB(red: 0.03, green: 0.05, blue: 0.2)
    #expect(DetailPalette(dominant: navy).background == navy)
    #expect(DetailPalette(dominant: .white).background == .white)
    #expect(DetailPalette(dominant: .black).background == .black)
  }

  @Test func aMidToneKeepsItsHueWhileMovingToReadable() {
    // The poster orange from the screenshot's neighborhood: readable with neither as is.
    let orange = RGB(red: 0.85, green: 0.35, blue: 0.1)
    let palette = DetailPalette(dominant: orange)

    #expect(palette.background != orange)
    // Still orange: red > green > blue.
    #expect(palette.background.red > palette.background.green)
    #expect(palette.background.green > palette.background.blue)
    // And it moved toward the side its text needs.
    if palette.usesLightText {
      #expect(palette.background.luminance < orange.luminance)
    } else {
      #expect(palette.background.luminance > orange.luminance)
    }
  }

  // MARK: - From image data

  @MainActor
  func png(_ color: UIColor, accent: UIColor? = nil) -> Data {
    let size = CGSize(width: 60, height: 90)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
      color.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      // A smaller block of another color: present, but not dominant.
      accent?.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 60, height: 20))
    }
  }

  @MainActor
  @Test func aPosterGivesAPaletteOfItsMainColor() throws {
    let data = png(
      UIColor(red: 0.05, green: 0.1, blue: 0.4, alpha: 1),
      accent: UIColor(red: 1, green: 0.9, blue: 0.2, alpha: 1))

    let palette = try #require(posterPalette(from: data))

    #expect(palette.usesLightText)
    // Blue, not the yellow block.
    #expect(palette.background.blue > palette.background.red)
    #expect(palette.background.blue > palette.background.green)
    #expect(palette.background.contrast(with: .white) >= 7)
  }

  @MainActor
  @Test func aLightPosterGetsDarkText() throws {
    let palette = try #require(
      posterPalette(from: png(UIColor(red: 0.95, green: 0.9, blue: 0.75, alpha: 1))))

    #expect(!palette.usesLightText)
    #expect(palette.background.contrast(with: .black) >= 7)
  }

  @Test func dataThatIsNotAnImageIsNil() {
    #expect(posterPalette(from: Data("not an image".utf8)) == nil)
    #expect(posterPalette(from: Data()) == nil)
  }

  @Test func aMissingPosterLoadsNothing() async {
    #expect(await loadPosterPalette(path: nil) == nil)
    #expect(await loadPosterPalette(path: "  ") == nil)
  }
}
