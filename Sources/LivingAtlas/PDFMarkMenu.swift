import AtlasCore
import PDFKit
import SwiftUI

struct PDFMarkMenu: View {
  let store: AtlasStore
  let file: AtlasPDF
  let selection: PDFAnchor?
  let changed: () -> Void
  let focus: (PDFAnchor) -> Void
  let failure: (String) -> Void
  var askPage: ((String) -> Void)? = nil
  @ViewState private var marks = [AtlasTextMark]()
  @ViewState private var showing = false
  @ViewState private var newComment: PDFAnchor?
  @ViewState private var text = ""
  @ViewState private var edit: AtlasTextMark?
  @ViewState private var inkSheet: InkSurface?
  @ViewState private var pagePicker = false
  @ViewState private var pageIndex = 1
  @ViewState private var pageCount = 1
  var body: some View {
    Menu("批注") {
      Button("高亮选句") { add(.highlight) }.disabled(selection?.versionID != file.versionID)
      Button("划线选句") { add(.underline) }.disabled(selection?.versionID != file.versionID)
      Button("写文字批注") {
        newComment = selection
        text = ""
        showing = true
      }.disabled(selection?.versionID != file.versionID)
      Divider()
      if let askPage {
        Button("引用当前页追问") {
          do {
            NotificationCenter.default.post(name: .atlasSavePDFPlace, object: store)
            let place = try store.readViewState(PDFReadingPlace.self, key: "pdf." + file.versionID)
            let ref = try store.capturePDFPage(versionID: file.versionID, page: place?.page ?? 0)
            askPage(ref)
          } catch { failure(error.localizedDescription) }
        }
      }
      Button("手写页面…") {
        do { pageCount = try store.readablePDF(file).pageCount } catch {
          failure(error.localizedDescription)
          return
        }
        let place = try? store.readViewState(PDFReadingPlace.self, key: "pdf." + file.versionID)
        pageIndex = min(
          pageCount, max(1, (selection?.segments.first?.pageIndex ?? place?.page ?? 0) + 1))
        pagePicker = true
      }
      Button("查看文档批注") {
        newComment = nil
        load()
        showing = true
      }
    }.menuStyle(.borderlessButton).fixedSize()
      .sheet(item: $inkSheet) { InkDesk(store: store, surface: $0, changed: changed) }
      .sheet(isPresented: $pagePicker) {
        VStack(alignment: .leading, spacing: 14) {
          Text("手写 PDF · 版本 \(file.ordinal)").font(.headline)
          Stepper("第 \(pageIndex) 页，共 \(pageCount) 页", value: $pageIndex, in: 1...max(1, pageCount))
          HStack {
            Spacer()
            Button("取消") { pagePicker = false }
            Button("打开版面") {
              do {
                let surface = try store.pdfInkSurface(version: file.versionID, page: pageIndex - 1)
                pagePicker = false
                DispatchQueue.main.async { inkSheet = surface }
              } catch { failure(error.localizedDescription) }
            }
          }
        }.padding(18).frame(width: 320)
      }
      .sheet(isPresented: $showing) {
        VStack(alignment: .leading, spacing: 12) {
          Text(file.title + " · 批注").font(.headline)
          if let newComment {
            Text(newComment.quote).lineLimit(4)
            TextEditor(text: $text).frame(height: 100)
            HStack {
              Spacer()
              Button("取消") { showing = false }
              Button("保存批注") { add(.text, anchor: newComment) }
            }
          } else {
            if marks.isEmpty { Text("还没有批注") }
            ScrollView {
              VStack(alignment: .leading, spacing: 12) {
                ForEach(marks) { m in
                  VStack(alignment: .leading, spacing: 4) {
                    Text(m.kind.label + " · 版本 \(m.ordinal)").font(.caption)
                    Text(m.quote).lineLimit(3)
                    if !m.text.isEmpty { Text(m.text).foregroundStyle(AtlasPalette.umber) }
                    HStack {
                      Button("返回原句") {
                        do {
                          let anchor = try store.pdfMarkAnchor(m)
                          showing = false
                          focus(anchor)
                        } catch { failure(error.localizedDescription) }
                      }
                      if m.kind == .text { Button("修改批注") { edit = m } }
                    }
                  }.frame(maxWidth: .infinity, alignment: .leading)
                  Divider()
                }
              }
            }
            HStack {
              Spacer()
              Button("关闭") { showing = false }
            }
          }
        }.padding(18).frame(width: 450).frame(minHeight: 220, maxHeight: 460)
          .sheet(item: $edit) { mark in
            EditWrittenComment(mark: mark) { text in
              try store.editComment(mark, text: text)
              load()
              changed()
            }
          }
      }
  }
  private func load() {
    do { marks = try store.textMarks(documentID: file.id) } catch {
      failure(error.localizedDescription)
    }
  }
  private func add(_ kind: TextMarkKind, anchor: PDFAnchor? = nil) {
    guard let a = anchor ?? selection, a.versionID == file.versionID else { return }
    do {
      try store.markPDF(a, kind: kind, text: text)
      changed()
      showing = false
    } catch { failure(error.localizedDescription) }
  }
}

extension DocumentReader.Coordinator {
  func displayTextMarks(_ file: AtlasPDF, change: UUID?, in view: PDFView) {
    guard let store, let document = view.document,
      marksDocument !== document || lastMarkChange != change
    else { return }
    do {
      let next=try store.pdfMarkLayers(for:file,in:document)
      for mark in installedMarks { mark.page?.removeAnnotation(mark) }
      for (page, mark) in next { page.addAnnotation(mark) }
      installedMarks = next.map(\.1)
      marksDocument = document
      lastMarkChange = change
    } catch { failure?(error.localizedDescription) }
  }
}
