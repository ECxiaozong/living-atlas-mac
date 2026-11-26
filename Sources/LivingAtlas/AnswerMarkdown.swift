import WebKit

/// A fixed, offline document. Model output only enters the isolated renderer as a string.
enum AnswerMarkdown {
  static let document = document(theme: .current)
  static func document(theme: AtlasTheme) -> String {
    """
    <!doctype html><html lang="zh-CN"><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; font-src atlas-font:; base-uri 'none'; form-action 'none';">
    <style>
      @font-face{font-family:AtlasWenKai;src:url("atlas-font://bundle/LXGWWenKai-Regular.ttf") format("truetype");font-display:swap}
      @font-face{font-family:AtlasFira;src:url("atlas-font://bundle/FiraCode-Regular.ttf") format("truetype");font-display:swap}
      :root{color-scheme:light}
      \(theme.css)
      ::selection{background:var(--atlas-selection,rgba(241,210,125,0.52));color:var(--atlas-ink,#252c31)}
      body{margin:4px 6px 14px 2px;color:var(--atlas-ink,#252c31);font:16px/1.76 var(--atlas-reading,AtlasWenKai),"PingFang SC",serif;-webkit-font-smoothing:antialiased}
      article{overflow-wrap:anywhere}p,ul,ol,pre,h1,h2,h3,h4,h5,h6{margin:0 0 .75em}
      ul,ol{padding-inline-start:1.65em}li+li{margin-top:.35em}
      li::marker{color:var(--atlas-secondaryInk,#8c6f4b)}strong{font-weight:620;color:var(--atlas-ink,#1d2429)}
      h1,h2,h3,h4,h5,h6{font-family:var(--atlas-reading,AtlasWenKai),"Songti SC",Georgia,serif;font-weight:600;line-height:1.45;color:var(--atlas-ink,#1e262c);margin-top:.9em}
      h1:first-child,h2:first-child,h3:first-child{margin-top:0}
      h1{font-size:1.22em}h2{font-size:1.12em}h3,h4,h5,h6{font-size:1.04em}
      code{font:.88em/1.55 var(--atlas-code,AtlasFira),ui-monospace,Menlo,monospace;white-space:pre-wrap;background:var(--atlas-inset,#f0e8da);color:var(--atlas-ink,#2a424f);padding:.06em .32em;border-radius:4px}
      blockquote{margin:.4em 0 .85em;padding:.45em .85em;border-left:2.5px solid var(--atlas-accent,#c59e5f);background:var(--atlas-inset,#f6f0e4);border-radius:0 6px 6px 0;color:var(--atlas-ink,#524637)}
      .callout{--accent:#486573;margin:.5em 0 .85em;padding:.5em .85em;border-inline-start:2px solid var(--accent);background:rgba(100,116,118,.055)}
      .callout-tip{--accent:#48675b}.callout-warning{--accent:#8a5b2c}.callout-question{--accent:#705776}
      .callout-title{font-weight:600;color:var(--accent);margin-bottom:.22em}
      .callout-title[data-label]::before{content:attr(data-label)}
      .callout>:last-child{margin-bottom:0}
      .table-wrap{overflow-x:auto;margin-bottom:.9em;border:1px solid var(--atlas-line,#dfd3c0);border-radius:7px;background:var(--atlas-paper,#faf6ed)}table{width:100%;border-collapse:collapse;font-size:.91em}
      th,td{padding:.48em .65em;text-align:left;vertical-align:top;border-bottom:1px solid var(--atlas-line,#e6dccb);min-width:5em}
      tr:last-child td{border-bottom:none}
      th:nth-child(3),td:nth-child(3){min-width:13em}
      th{color:var(--atlas-ink,#4e4030);font-weight:600;background:var(--atlas-inset,#f2eadb);border-bottom:1px solid var(--atlas-line,#d4c4ab)}
      .table-wrap,pre,.math-block{overscroll-behavior-x:contain}
      .language{color:var(--atlas-secondaryInk,#776149);font:.74em/1.4 var(--atlas-code,AtlasFira),ui-monospace,Menlo,monospace;text-transform:uppercase;letter-spacing:.05em;margin-bottom:3px}
      pre{overflow-x:auto;white-space:pre;overflow-wrap:normal;padding:.65em .8em;border:1px solid var(--atlas-line,#e2d6c3);border-inline-start:2.5px solid var(--atlas-accent,#b5966a);background:var(--atlas-inset,#f6f0e4);border-radius:6px}
      pre code{white-space:pre;background:transparent;color:var(--atlas-ink,#23313a);padding:0}
      .math-block{overflow-x:auto;margin:.55em 0 .85em;text-align:center}
      math{font-family:math;font-size:1.06em} .math-block math{margin-inline:auto}
      .math-source{font-family:var(--atlas-code,AtlasFira),ui-monospace,Menlo,monospace;white-space:pre-wrap}
      code,.math-source{font-variant-ligatures:common-ligatures contextual;font-feature-settings:"calt" 1,"liga" 1}
      #ask-fragment{position:absolute;z-index:2;font:500 12.5px var(--atlas-reading,AtlasWenKai),-apple-system,sans-serif;color:#fcf9f2;background:var(--atlas-accent,#2a4c5d);border:1px solid rgba(255,255,255,0.18);border-radius:7px;padding:5px 11px;box-shadow:0 3px 10px rgba(30,24,16,0.22);cursor:pointer;transition:background-color .14s ease,transform .12s ease}
      #ask-fragment:hover{background:var(--atlas-accent,#203e4e)}
      #ask-fragment:active{transform:scale(0.98)}
      #latest{position:sticky;bottom:4px;float:right;margin:3px 4px;padding:4px 11px;
        font:500 12px var(--atlas-reading,AtlasWenKai),-apple-system,sans-serif;color:var(--atlas-accent,#2a4c5d);background:#fcf9f2;border:1px solid var(--atlas-line,#bfa88b);border-radius:999px;box-shadow:0 2px 6px rgba(30,24,16,0.12);cursor:pointer;transition:background-color .14s ease,border-color .14s ease}
      #latest:hover{background:#f3ecde;border-color:#9e8667}
      @media (prefers-reduced-motion:reduce){#ask-fragment,#latest{transition:none}}
    </style><article id="answer"></article><button id="latest" type="button" hidden>↓ 新内容</button></html>
    """
  }
  static let install: String = {
    // The native view falls back to plain text if a packaged resource is unavailable.
    return ["libraries.js", "callouts.js", "reader.js"].compactMap { name -> String? in
      guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "AnswerRendering")
      else { return nil }
      return try? String(contentsOf: url, encoding: .utf8)
    }.joined(separator: "\n;\n")
  }()
}
