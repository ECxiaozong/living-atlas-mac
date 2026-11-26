import AtlasCore
import SwiftUI

extension Session {
  var displayedCitation: PDFAnchor? {
    guard let version = shownPDF?.versionID else { return nil }
    let candidates = [current?.anchor, anchor].compactMap { $0 }.filter { $0.versionID == version }
    if let highlight, candidates.contains(highlight), returnToQuestion { return highlight }
    return candidates.first
  }
}

struct ReadingPaper: View {
  @ObservedObject var s: Session
  let store: AtlasStore
  @Binding var selection: PDFAnchor?
  @ViewState private var lockedVersion: String?
  @ViewState private var unlockChange: UUID?
  @ViewState private var markChange: UUID?
  @ViewState private var zoomRequest: PDFZoomRequest?
  let move: (NSPoint, Bool) -> Void
  let reset: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        AtlasKindBadge(kind: .pdf)
        SheetTitle(text: s.shownPDF?.title ?? "阅读资料", move: move, reset: reset)
        if let file = s.shownPDF {
          Text("版本 " + String(file.ordinal)).font(.system(size: 12)).foregroundStyle(
            AtlasPalette.umber)
        }
        if let file = s.shownPDF {
          Button("选页放到画布") {
            s.pageToPlace = Session.PDFPageRequest(file: file, index: nil)
            s.area = .overview
          }.buttonStyle(PaperButton(compact: true))
        }
        Menu {
          if let file = s.shownPDF {
            Button("把这一页放到画布") {
              NotificationCenter.default.post(name: .atlasSavePDFPlace, object: store)
              let index = (try? store.readViewState(PDFReadingPlace.self, key: "pdf."+file.versionID))?.page ?? 0
              s.pageToPlace = Session.PDFPageRequest(file: file, index: index)
              s.area = .overview
            }
            Button("放大原文") {
              zoomRequest = PDFZoomRequest(action: .zoomIn, versionID: file.versionID)
            }
            Button("缩小原文") {
              zoomRequest = PDFZoomRequest(action: .zoomOut, versionID: file.versionID)
            }
            Button("适合宽度") {
              zoomRequest = PDFZoomRequest(action: .fitWidth, versionID: file.versionID)
            }
            Divider()
          }
          if !s.docs.isEmpty {
            ForEach(s.docs) { file in Button(file.title) { s.openDocument(file) } }
            Divider()
          }
          Button("导入 PDF…") { s.importDocument(update: false) }
          if s.shownPDF != nil { Button("导入新版本…") { s.importDocument(update: true) } }
        } label: {
          Image(systemName: "ellipsis.circle").font(.system(size: 16)).foregroundStyle(AtlasPalette.umber)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("阅读选项与资料管理").help(
          "调整原文大小、切换资料或导入新版本")
      }
      .padding(.horizontal, 19).frame(height: 44).background(AtlasPalette.paperHeader.opacity(0.62))
      PaperRule()
      if let file = s.shownPDF {
        DocumentReader(
          file: file, store: store, focus: s.highlight, focusRequest: s.sourceFocusRequest,
          citation: s.displayedCitation, zoomRequest: zoomRequest, markChange: markChange, locked: { lockedVersion=$0 },
          selected: { anchor in
            guard s.shownPDF?.versionID == file.versionID else { return }
            selection = anchor
          }, failure: { s.error = $0 }
        )
        .id(unlockChange)
        .overlay {
          if lockedVersion == file.versionID {
            Button("解锁 PDF") {
              guard let password = promptPDFPassword(file.title) else{return}
              do {_ = try store.readablePDF(file,password:password);lockedVersion=nil;unlockChange=UUID()}catch{s.error=error.localizedDescription}
            }.buttonStyle(PaperButton(primary:true))
          }
        }
        .padding(.horizontal, 10).padding(.top, 8)
        PaperRule().padding(.horizontal, 16)
        HStack {
          if selection?.versionID == file.versionID {
            Image(systemName: "text.quote").foregroundStyle(AtlasPalette.umber)
            Text("已选择原文").font(.caption)
          } else {
            Text("选择原文中的一段文字").font(.caption)
          }
          Spacer()
          PDFMarkMenu(store:store,file:file,selection:selection,changed:{markChange=UUID()},focus:{s.follow($0)},failure:{s.error=$0},askPage:{s.ask(reference:$0)})
          if s.returnToQuestion {
            Button("返回问题") { s.backToQuestion() }.buttonStyle(PaperButton())
          }
          Button("选句追问") {
            guard let anchor = selection, anchor.versionID == file.versionID else { return }
            s.beginQuestion(from: anchor)
          }.buttonStyle(PaperButton()).disabled(selection?.versionID != file.versionID)
        }.foregroundStyle(AtlasPalette.blueInk).padding(.horizontal, 18).frame(height: 43)
      } else {
        VStack(spacing: 14) {
          Image(systemName: "book.pages").font(.system(size: 32, weight: .light))
            .foregroundStyle(AtlasPalette.umber)
          Text("在这里阅读原文").font(AtlasTypeface.reading.font(23))
          Text("导入 PDF 后，可以选中原句继续提问。").font(.callout).foregroundStyle(AtlasPalette.blueInk)
          Button("导入 PDF…") { s.importDocument(update: false) }.buttonStyle(PaperButton())
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity).paperSheet()
  }
}
