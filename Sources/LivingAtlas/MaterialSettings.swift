import AtlasCore
import SwiftUI

struct MaterialSettings: View {
  let store: AtlasStore
  let run: AtlasRun?
  @Environment(\.dismiss) var dismiss
  @ViewState private var settings = ContextSettings()
  @ViewState private var manifest: [String: Any] = [:]
  @ViewState private var problem = ""
  @ViewState private var usage: RunUsage?
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 9) {
        AtlasArt.compass.resizable().scaledToFit().frame(width: 19, height: 19).accessibilityHidden(true)
        Text("材料范围")
          .font(AtlasTypeface.reading.font(21).weight(.medium))
          .foregroundStyle(AtlasPalette.ink)
        Spacer()
        Button("关闭") { dismiss() }
          .buttonStyle(PaperButton(compact: true))
      }
      PaperRule()
      VStack(alignment: .leading, spacing: 10) {
        Picker("追问范围", selection: $settings.scope) {
          Text("直接来源与更早讨论").tag(ContextSettings.Scope.branch)
          Text("仅直接来源").tag(ContextSettings.Scope.direct)
          Text("独立解读选段").tag(ContextSettings.Scope.selection)
        }
        Text("直接来源包含母问题和选中回答当时的语境。独立解读只提供明确选段与引用。")
          .font(.system(size: 11.5))
          .foregroundStyle(AtlasPalette.umber)
        HStack(spacing: 8) {
          Text("输入预算").font(.system(size: 12.5))
          TextField("输入预算", value: $settings.inputBudget, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .frame(width: 96)
          Text("字节 · 序列化请求上限")
            .font(.system(size: 11.5))
            .foregroundStyle(AtlasPalette.umber)
        }
      }
      .padding(12)
      .background(AtlasPalette.paperInset.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(AtlasPalette.line.opacity(0.4), lineWidth: 0.75)
      }
      HStack {
        Spacer()
        Button("保存范围") {
          do {
            try store.setContextSettings(settings)
            dismiss()
          } catch { problem = error.localizedDescription }
        }
        .buttonStyle(PaperButton(primary: true))
      }
      if run != nil {
        PaperRule()
        Text("实际用量 · 输入 " + (usage?.input.map(String.init) ?? "未知")
          + " · 输出 " + (usage?.output.map(String.init) ?? "未知")
          + " · 缓存读取 " + (usage?.cachedInput.map(String.init) ?? "未知"))
          .font(AtlasTypeface.code.font(11.5))
          .foregroundStyle(AtlasPalette.umber)
        Text("此次生成使用的材料")
          .font(AtlasTypeface.reading.font(15.5).weight(.medium))
        if let rows = manifest["materials"] as? [[String: Any]] {
          if rows.isEmpty {
            Text("仅发送了问题。")
              .font(.system(size: 12.5))
              .foregroundStyle(AtlasPalette.umber)
          }
          ScrollView {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(rows.indices, id: \.self) { i in
                let row = rows[i]
                let source = row["source"] as? [String: Any]
                let provided = row["provided"] as? [String: Any]
                let kind = row["selection_kind"] as? String ?? ""
                let names = ["origin": "追问原句", "history": "此前讨论", "summary": "较早讨论摘录", "explicit": "所附材料"]
                VStack(alignment: .leading, spacing: 4) {
                  Text((names[kind] ?? kind) + " · " + (source?["version_id"] as? String ?? ""))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AtlasPalette.umber)
                  Text(provided?["text"] as? String ?? "")
                    .font(AtlasTypeface.reading.font(13.5))
                    .lineSpacing(2.5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(AtlasPalette.paperInset.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                  RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(AtlasPalette.line.opacity(0.35), lineWidth: 0.7)
                }
              }
            }
          }.frame(maxHeight: 220)
          if let skipped = manifest["omitted_materials"] as? [[String: Any]], !skipped.isEmpty {
            Text("因预算省略的较早材料")
              .font(AtlasTypeface.reading.font(14.5).weight(.medium))
              .foregroundStyle(AtlasPalette.umber)
            ForEach(skipped.indices, id: \.self) { i in
              Text((skipped[i]["source"] as? [String: String])?["version_id"] ?? "")
                .font(AtlasTypeface.code.font(11.5))
                .foregroundStyle(AtlasPalette.umber)
            }
          }
        } else {
          Text("这条历史记录没有保存材料清单。")
            .font(.system(size: 12.5))
            .foregroundStyle(AtlasPalette.umber)
        }
      }
      if !problem.isEmpty {
        Text(problem).font(.system(size: 12.5)).foregroundStyle(AtlasPalette.terracotta)
      }
    }
    .padding(22)
    .frame(width: 460)
    .background(AtlasPalette.paper)
    .foregroundStyle(AtlasPalette.ink)
    .onAppear {
      do {
        settings = try store.contextSettings()
        if let run, let json = try store.materialManifest(run.id) {
          usage = try store.usage(for: run.id)
          manifest =
            (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        }
      } catch { problem = error.localizedDescription }
    }
  }
}
