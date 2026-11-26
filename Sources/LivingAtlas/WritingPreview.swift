import AppKit
import AtlasCore
import SwiftUI
import WebKit

struct WritingPreview: NSViewRepresentable {
  struct Mark: Codable, Equatable {
    let kind: String
    let parts: [WritingSelection]
  }
  var imageStore: AtlasStore? = nil
  var imageVersion: String? = nil
  var readingVersion: String? = nil
  var placementID: String? = nil
  var onFailure: ((String) -> Void)? = nil
  var imageLinks: [String: String] = [:]
  let page: WrittenPage
  let marks: [Mark]
  let focus: [WritingSelection]?
  var onReady: ((WKWebView) -> Void)? = nil
  var onGesture: ((Bool) -> Void)? = nil
  var onRestoreSelection: (([WritingSelection]) -> Void)? = nil
  let onSelect: ([WritingSelection]) -> Void
  static let script = """
    const root=document.querySelector('article');
    let interacted=false, restored=false;
    document.addEventListener('pointerdown',()=>{interacted=true});
    root.addEventListener('pointerdown',()=>window.webkit.messageHandlers.gesture.postMessage('begin'));
    document.addEventListener('keydown',()=>{interacted=true});
    for(const event of ['pointerup','pointercancel','blur']) {
      window.addEventListener(event,()=>window.webkit.messageHandlers.gesture.postMessage('end'));
    }
    // A canvas click may collapse the range before WebKit reports document focus.
    // Explicit input clears the bookmark; losing focus to the overview toolbar does not.
    function clearIfCollapsed(){
      if(getSelection().isCollapsed){
        window.webkit.messageHandlers.selection.postMessage(JSON.stringify({parts:[],backward:false}));
      }
    }
    document.addEventListener('click',clearIfCollapsed);
    document.addEventListener('keyup',clearIfCollapsed);
    root.addEventListener('click', e=>{
      const a=e.target.closest('a');
      if(a){e.preventDefault(); window.webkit.messageHandlers.openLink.postMessage(a.getAttribute('href')||'');}
    });
    function place(){
      const b=[...root.children].find(e=>e.getBoundingClientRect().bottom>0);
      if(b)window.webkit.messageHandlers.place.postMessage(JSON.stringify({block:Number(b.dataset.block),offset:-b.getBoundingClientRect().top}));
    }
    let selectedTop = null, viewportWidth = innerWidth, viewportHeight = innerHeight;
    function selectionRect(){
      const s=getSelection();
      if(!s.rangeCount || s.isCollapsed || !root.contains(s.anchorNode))return null;
      return s.getRangeAt(0).getBoundingClientRect();
    }
    function rememberSelection(){
      // WebKit may deliver a scroll notification before the resize that caused it.
      if(viewportWidth!==innerWidth || viewportHeight!==innerHeight)return;
      const r=selectionRect();
      selectedTop=r && r.bottom>0 && r.top<innerHeight ? r.top : null;
    }
    window.addEventListener('resize',()=>{
      viewportWidth=innerWidth; viewportHeight=innerHeight;
      const r=selectionRect();
      if(selectedTop!==null && r){
        const height=r.bottom-r.top;
        const target=Math.max(1-height,Math.min(selectedTop,innerHeight-1));
        if(Math.abs(r.top-target)>1)scrollBy(0,r.top-target);
      }
    });
    window.addEventListener('scroll',()=>{place();rememberSelection()},{passive:true});
    document.addEventListener('visibilitychange',()=>{if(document.hidden)place()});
    function selectedParts(r){
      const parts=[];
      for(const b of root.children){
        if(!r.intersectsNode(b))continue;
        const inside=document.createRange();inside.selectNodeContents(b);
        if(b.contains(r.startContainer))inside.setStart(r.startContainer,r.startOffset);
        if(b.contains(r.endContainer))inside.setEnd(r.endContainer,r.endOffset);
        const quote=inside.toString();
        if(!quote)continue;
        const before=document.createRange();before.selectNodeContents(b);before.setEnd(inside.startContainer,inside.startOffset);
        const start=Array.from(before.toString()).length;
        parts.push({block:Number(b.dataset.block),start,end:start+Array.from(quote).length,quote});
      }
      return parts;
    }
    document.addEventListener('selectionchange',()=>{
      rememberSelection();
      const s=getSelection(),r=s.rangeCount && !s.isCollapsed ? s.getRangeAt(0) : null;
      const parts=r ? selectedParts(r) : [];
      // Focus transfer to the native composer can collapse the DOM range before blur.
      // Only an explicit click or key release in the reader clears the saved selection.
      if(parts.length){
        const backward=!!r && s.anchorNode===r.endContainer && s.anchorOffset===r.endOffset;
        const handler=restored && !interacted ? 'restoredSelection' : 'selection';
        window.webkit.messageHandlers[handler].postMessage(JSON.stringify({parts,backward}));
      }
      restored=false;
    });
    function makeRange(p){
      const b=root.querySelector('[data-block="'+p.block+'"]'); if(!b)return null;
      let at=0, range=new Range(),begun=false;
      const nodes=document.createTreeWalker(b,NodeFilter.SHOW_TEXT);
      for(let n=nodes.nextNode();n;n=nodes.nextNode()){
        const chars=Array.from(n.data),end=at+chars.length;
        if(!begun && p.start>=at && p.start<end){
          range.setStart(n,chars.slice(0,p.start-at).join('').length);begun=true;
        }
        if(begun && p.end<=end){
          range.setEnd(n,chars.slice(0,p.end-at).join('').length);
          return range.toString()===p.quote ? range : null;
        }
        at=end;
      }
      return null;
    }
    function restoreSelection(saved){
      if(interacted || !saved.parts.length || !getSelection().isCollapsed)return;
      const first=makeRange(saved.parts[0]), last=makeRange(saved.parts[saved.parts.length-1]);
      if(!first || !last)return;
      const r=new Range();
      r.setStart(first.startContainer,first.startOffset);r.setEnd(last.endContainer,last.endOffset);
      const parts=selectedParts(r);
      if(parts.length!==saved.parts.length || !parts.every((p,i)=>{
        const q=saved.parts[i];
        return p.block===q.block && p.start===q.start && p.end===q.end && p.quote===q.quote;
      }))return;
      const start=[r.startContainer,r.startOffset],end=[r.endContainer,r.endOffset];
      restored=true;
      getSelection().setBaseAndExtent(...(saved.backward ? end : start),...(saved.backward ? start : end));
    }
    window.decorate=(marks,focus)=>{
      for(const kind of ['highlight','underline','text','target']){
        const ranges=(kind==='target'?(focus||[]):marks.filter(m=>m.kind===kind).flatMap(m=>m.parts)).map(makeRange).filter(Boolean);
        if(window.Highlight)CSS.highlights.set(kind,new Highlight(...ranges));
        if(kind==='target' && ranges.length)ranges[0].startContainer.parentElement.scrollIntoView({block:'center'});
      }
    }
    """
  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate,
    WKURLSchemeHandler
  {
    struct Place: Codable, Equatable {
      let block: Int
      let offset: Double
    }
    struct SelectionBookmark: Codable, Equatable {
      let parts: [WritingSelection]
      let backward: Bool
    }
    var selectionKey: String?
    var bookmark: SelectionBookmark?
    var pendingSelection = false
    var dragging = false
    func saveSelection() {
      guard pendingSelection, let bookmark, let selectionKey, let store else { return }
      do {
        try store.saveViewState(bookmark, key: selectionKey)
        pendingSelection = false
      } catch { onFailure?(error.localizedDescription) }
    }
    var store: AtlasStore?, imageVersion: String?, imageLinks: [String: String] = [:]
    var readingVersion: String?, lastPlace: Place?, onFailure: ((String) -> Void)?
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
      do {
        guard let url = urlSchemeTask.request.url, url.scheme == "atlas-asset", let hash = url.host,
          let store, let imageVersion
        else { throw URLError(.fileDoesNotExist) }
        let (bytes, mime) = try store.readWritingImage(hash: hash, version: imageVersion)
        urlSchemeTask.didReceive(
          URLResponse(
            url: url, mimeType: mime, expectedContentLength: bytes.count, textEncodingName: nil))
        urlSchemeTask.didReceive(bytes)
        urlSchemeTask.didFinish()
      } catch { urlSchemeTask.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
    var onReady: ((WKWebView) -> Void)?
    var onSelect: (([WritingSelection]) -> Void)?
    var onRestoreSelection: (([WritingSelection]) -> Void)?
    var onGesture: ((Bool) -> Void)?
    var markup: String?, marks: [Mark] = [], focus: [WritingSelection]?
    var navigation: WKNavigation?
    var ready = false
    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard message.frameInfo.isMainFrame, let body = message.body as? String else { return }
      if message.name == "place", ready, let version = readingVersion,
        let next = try? JSONDecoder().decode(Place.self, from: Data(body.utf8)),
        next.block >= 0, next.offset.isFinite, next != lastPlace
      {
        lastPlace = next
        do { try store?.saveViewState(next, key: "markdown.position." + version) } catch {
          onFailure?(error.localizedDescription)
        }
      } else if message.name == "gesture", ready {
        dragging = body == "begin"
        if !dragging { saveSelection() }
        onGesture?(dragging)
      } else if message.name == "openLink" {
        guard let url = URL(string: body),
          ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
        else { return }
        NSWorkspace.shared.open(url)
      } else if ["selection", "restoredSelection"].contains(message.name), ready,
        let next = try? JSONDecoder().decode(SelectionBookmark.self, from: Data(body.utf8))
      {
        if message.name == "restoredSelection", bookmark == next {
          (onRestoreSelection ?? onSelect)?(next.parts)
          return
        }
        if selectionKey != nil, bookmark != next {
          bookmark = next
          pendingSelection = true
          if !dragging { saveSelection() }
        }
        onSelect?(next.parts)
      }
    }
    func updateDecoration(in web: WKWebView) {
      guard ready, let bytes = try? JSONEncoder().encode(marks),
        let markArray = try? JSONSerialization.jsonObject(with: bytes),
        let selection = try? JSONEncoder().encode(focus ?? []),
        let focusArray = try? JSONSerialization.jsonObject(with: selection)
      else { return }
      web.callAsyncJavaScript(
        "window.decorate(marks,focus)", arguments: ["marks": markArray, "focus": focusArray],
        in: nil, in: .defaultClient, completionHandler: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard let navigation, self.navigation === navigation else { return }
      ready = true
      webView.callAsyncJavaScript(
        """
        await Promise.all([...document.querySelectorAll('[data-image-ref]')].map(async e=>{
          const hash=links[e.getAttribute('data-image-ref')];if(!hash)return;
          const img=new Image();img.alt='';img.src='atlas-asset://'+hash;
          try{await img.decode();e.prepend(img);e.classList.remove('missing')}catch{}
        }));
        return true;
        """, arguments: ["links": imageLinks], in: nil, in: .defaultClient
      ) { [weak self, weak webView] _ in
        guard let self, self.ready, self.navigation === navigation, let webView else { return }
        if self.focus == nil, let version = self.readingVersion {
          do {
            if !self.pendingSelection, let key = self.selectionKey, let saved = try self.store?.readViewState(SelectionBookmark.self, key: key),
              let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any]
            {
              self.bookmark = saved
              webView.callAsyncJavaScript("restoreSelection(saved)", arguments: ["saved": object],
                in: nil, in: .defaultClient, completionHandler: nil)
            }
            if let p = try self.store?.readViewState(
              Place.self, key: "markdown.position." + version)
            {
              self.lastPlace = p
              webView.callAsyncJavaScript(
                "const e=document.querySelectorAll('article > section')[block];if(e)scrollBy(0,e.getBoundingClientRect().top+offset)",
                arguments: ["block": p.block, "offset": p.offset], in: nil, in: .defaultClient,
                completionHandler: nil)
            }
          } catch { self.onFailure?(error.localizedDescription) }
        }
        self.updateDecoration(in: webView)
        self.onReady?(webView)
      }
    }
    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      if let markup {
        ready = false
        navigation = webView.loadHTMLString(markup, baseURL: nil)
      }
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    AtlasFontScheme.install(in: config)
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(context.coordinator, forURLScheme: "atlas-asset")
    for name in ["selection", "restoredSelection", "openLink", "place", "gesture"] {
      config.userContentController.add(
        context.coordinator, contentWorld: .defaultClient, name: name)
    }
    config.userContentController.addUserScript(
      WKUserScript(
        source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
        in: .defaultClient))
    let web = context.environment.canvasReaderFactory.web(config)
    context.environment.canvasTextCoordinates?.installPinch(on: web)
    web.navigationDelegate = context.coordinator
    web.setValue(false, forKey: "drawsBackground")
    return web
  }
  static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
    coordinator.saveSelection()
    coordinator.navigation = nil
    coordinator.ready = false
    coordinator.onReady = nil
    coordinator.onSelect = nil
    coordinator.onRestoreSelection = nil
    coordinator.onGesture = nil
    coordinator.onFailure = nil
    coordinator.store = nil
    web.navigationDelegate = nil
    web.configuration.userContentController.removeAllScriptMessageHandlers(from: .defaultClient)
    web.stopLoading()
  }
  func updateNSView(_ web: WKWebView, context: Context) {
    let c = context.coordinator
    let readingKey =
      placementID.map { CanvasWritingState.positionPrefix($0) }.flatMap { prefix in
        readingVersion.map { prefix + $0 }
      } ?? readingVersion
    let changedReader = c.readingVersion != readingKey || c.store !== imageStore
    if changedReader {
      c.saveSelection()
      c.bookmark = nil
      c.pendingSelection = false
      c.dragging = false
      c.lastPlace = nil
    }
    c.readingVersion = readingKey
    c.selectionKey = placementID == nil ? nil : readingKey.map { "markdown.selection." + $0 }
    c.onFailure = onFailure
    c.store = imageStore
    c.imageVersion = imageVersion
    c.imageLinks = imageLinks
    c.onReady = onReady
    c.onSelect = onSelect
    c.onRestoreSelection = onRestoreSelection
    c.onGesture = onGesture
    let changed = c.marks != marks || c.focus != focus
    c.marks = marks
    c.focus = focus
    let doc = page.previewDocument
    if c.markup != doc || changedReader {
      c.saveSelection()
      c.dragging = false
      c.ready = false
      c.markup = doc
      c.navigation = web.loadHTMLString(doc, baseURL: nil)
    } else if changed {
      c.updateDecoration(in: web)
    }
  }
}
