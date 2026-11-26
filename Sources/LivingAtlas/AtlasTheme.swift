import AppKit
import SwiftUI

/// Version 1 themes supply values only. Unspecified roles inherit the built-in atlas.
struct AtlasTheme {
  static let current: AtlasTheme = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    let file = base?.appendingPathComponent("Living Atlas/theme.json")
    guard let file, let data = try? Data(contentsOf: file), let theme = try? AtlasTheme(data: data) else {
      return AtlasTheme()
    }
    return theme
  }()

  enum Role: String, CaseIterable {
    case ink, secondaryInk, accent, line, paper, inset, selection
  }
  private var colors: [Role: String] = [:]
  private var fonts: [String: String] = [:]

  init() {}
  init(data: Data) throws {
    struct File: Decodable {
      let version: Int
      let colors: [String: String]?
      let fonts: [String: String]?
    }
    let file = try JSONDecoder().decode(File.self, from: data)
    guard file.version == 1 else { throw CocoaError(.fileReadUnsupportedScheme) }
    for role in Role.allCases {
      if let hex = file.colors?[role.rawValue],
        hex.range(of: #"\A#[0-9a-fA-F]{6}\z"#, options: .regularExpression) != nil {
        colors[role] = hex
      }
    }
    for name in ["reading", "code"] {
      if let value = file.fonts?[name],
        value.range(of: #"\A[A-Za-z0-9 _.-]{1,100}\z"#, options: .regularExpression) != nil,
        NSFont(name: value, size: 14) != nil { fonts[name] = value }
    }
  }

  func nativeColor(_ role: Role) -> NSColor? {
    guard let hex = colors[role], let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat(rgb >> 16) / 255,
                   green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
  }
  func color(_ role: Role, default fallback: Color) -> Color {
    nativeColor(role).map { Color(nsColor: $0) } ?? fallback
  }
  func fontName(_ face: AtlasTypeface) -> String? { fonts[face == .reading ? "reading" : "code"] }

  var css: String {
    var values = Role.allCases.compactMap { role in colors[role].map { "--atlas-\(role.rawValue):\($0)" } }
    for name in ["reading", "code"] {
      if let font = fonts[name] { values.append("--atlas-\(name):'\(font)'") }
    }
    return values.isEmpty ? "" : ":root{" + values.joined(separator: ";") + "}"
  }
}
