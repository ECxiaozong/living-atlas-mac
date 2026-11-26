import AtlasCore
import Foundation
import JavaScriptCore

private final class BlockText: NSObject, XMLParserDelegate {
  var value = ""
  var images = [String]()
  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes: [String: String] = [:]
  ) {
    if elementName == "span", let ref = attributes["data-image-ref"] { images.append(ref) }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) { value += string }
  func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
    value += whitespaceString
  }
}

final class WrittenPage {
  struct Block {
    let content: WrittenBlock
    let html: String
  }
  let blocks: [Block]
  init(blocks: [Block]) { self.blocks = blocks }
  var html: String {
    blocks.enumerated().map { "<section data-block=\"\($0.offset)\">\($0.element.html)</section>" }
      .joined()
  }
  // SwiftUI updates the reader during viewport and selection changes. Each parsed page
  // supplies one immutable WebKit document, shared across those updates.
  @MainActor private(set) lazy var previewDocument = AnswerMarkdown.document.replacingOccurrences(
      of: "default-src 'none';", with: "default-src 'none'; img-src atlas-asset:;"
    ).replacingOccurrences(
      of:
        "<article id=\"answer\"></article><button id=\"latest\" type=\"button\" hidden>↓ 新内容</button>",
      with: """
        <style>html,body{overscroll-behavior:contain}body{padding:6px 8px 12px}article{font-size:15.5px;line-height:1.78}section{overflow-x:auto}section:first-child h1:first-child{font-size:1.12em;color:var(--atlas-ink,#574837);margin-bottom:.5em;padding-bottom:.25em;border-bottom:1px solid rgba(190,168,139,0.32)}a{color:var(--atlas-accent,#2a4c5d);text-underline-offset:3px}
        ::highlight(highlight){background:#f2d891}::highlight(underline){text-decoration:underline solid #ac7945}
        ::highlight(text){text-decoration:underline dotted #735ba7}::highlight(target){background:var(--atlas-selection,#efd394)}
        .illustration{display:inline-block;font-size:.85em;color:#746349}.illustration img{display:block;max-width:100%;height:auto;border-radius:6px}
        .missing::after{content:"（图片未载入）"}</style><article>\(html)</article>
        """)
}

/// One offline parser supplies both block identities and the markup used for selecting a source.
@MainActor
enum WrittenMarkdown {
  private static let parser: JSValue? = {
    guard
      let url = Bundle.module.url(
        forResource: "libraries.js", withExtension: nil, subdirectory: "AnswerRendering"),
      let library = try? String(contentsOf: url, encoding: .utf8),
      let callouts = Bundle.module.url(forResource: "callouts.js", withExtension: nil, subdirectory: "AnswerRendering"),
      let extensionScript = try? String(contentsOf: callouts, encoding: .utf8),
      let context = JSContext()
    else { return nil }
    context.evaluateScript(library)
    context.evaluateScript(extensionScript)
    return context.evaluateScript(
      """
      (function() {
        function makeParser(callouts) {
          const md = markdownit({html:false, xhtmlOut:true, breaks:true});
          const escape = md.utils.escapeHtml;
          md.renderer.rules.image = (tokens,i) => '<span class="illustration missing" data-image-ref="'+
            escape(tokens[i].attrGet('src')||'')+'">'+
            escape('〔图 · '+(tokens[i].content || '未命名图片')+'〕')+'</span>';
          if (callouts) installAtlasCallouts(md);
          return md;
        }
        const current = makeParser(true), legacy = makeParser(false);
        return function(source, callouts) {
          const md = callouts ? current : legacy;
          const env={}, ts=md.parse(source,env), lines=source.split('\\n');
          let offsets=[0], at=0;
          for (let i=0;i<lines.length;i++) {
            at+=Array.from(lines[i]).length + (i<lines.length-1?1:0);
            offsets.push(at);
          }
          const out=[];
          let begin=0;
          for(let i=0;i<ts.length;i++) {
            if(ts[i].level!==0 || ts[i].nesting===1) continue;
            const first=ts[begin], span=first.map;
            if(!span) throw new Error('missing source range');
            out.push({kind:first.type.replace(/_open$/,''),start:offsets[span[0]],end:offsets[span[1]],
              html:md.renderer.render(ts.slice(begin,i+1),md.options,env).trimEnd()});
            begin=i+1;
          }
          return JSON.stringify(out);
        };
      })()
      """)
  }()

  static func parse(_ source: String, callouts: Bool = true) throws -> WrittenPage {
    guard let parser, let result = parser.call(withArguments: [source, callouts])?.toString() else {
      throw AtlasStoreError.invalid("本地 Markdown 解析器未能打开，草稿仍可编辑。")
    }
    struct Block: Decodable {
      let kind: String
      let start: Int
      let end: Int
      let html: String
    }
    let items = try JSONDecoder().decode([Block].self, from: Data(result.utf8))
    return WrittenPage(
      blocks: try items.map { block in
        let collector = BlockText()
        let xml = XMLParser(data: Data("<section>\(block.html)</section>".utf8))
        xml.delegate = collector
        xml.shouldResolveExternalEntities = false
        guard xml.parse() else {
          throw xml.parserError ?? AtlasStoreError.invalid("无法提取本段 Markdown 原文。")
        }
        return WrittenPage.Block(
          content: WrittenBlock(
            kind: block.kind, start: block.start, end: block.end,
            text: collector.value, images: collector.images), html: block.html)
      })
  }
}
