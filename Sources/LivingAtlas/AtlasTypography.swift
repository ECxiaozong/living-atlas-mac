import CoreText
import SwiftUI
import WebKit

enum AtlasTypeface: String, CaseIterable {
  case reading = "LXGWWenKai-Regular"
  case code = "FiraCode-Regular"

  fileprivate var url: URL? {
    Bundle.module.url(forResource: rawValue, withExtension: "ttf", subdirectory: "Fonts")
  }

  private static let register: Void = {
    for face in allCases {
      if let url = face.url { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }
  }()

  func native(_ size: CGFloat) -> NSFont {
    _ = Self.register
    if let name = AtlasTheme.current.fontName(self), let font = NSFont(name: name, size: size) { return font }
    if let font = NSFont(name: rawValue, size: size) { return font }
    return self == .code ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
  }

  func font(_ size: CGFloat) -> Font { Font(native(size)) }
}

// WebKit renders in a separate process. Serve only the two packaged faces to both readers.
final class AtlasFontScheme: NSObject, WKURLSchemeHandler {
  static let scheme = "atlas-font"

  static func install(in config: WKWebViewConfiguration) {
    config.setURLSchemeHandler(AtlasFontScheme(), forURLScheme: scheme)
  }

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let url = task.request.url, url.host == "bundle",
      let face = AtlasTypeface.allCases.first(where: { url.path == "/" + $0.rawValue + ".ttf" }),
      let file = face.url
    else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
    do {
      let data = try Data(contentsOf: file, options: .mappedIfSafe)
      let headers = ["Content-Type": "font/ttf", "Content-Length": String(data.count),
        "Access-Control-Allow-Origin": "*", "Cache-Control": "max-age=31536000, immutable"]
      guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
      else { throw URLError(.badServerResponse) }
      task.didReceive(response)
      task.didReceive(data)
      task.didFinish()
    } catch { task.didFailWithError(error) }
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
