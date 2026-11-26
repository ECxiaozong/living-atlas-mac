import AtlasCore
import SwiftUI

struct AgentAccessPanel: View {
  @Environment(\.dismiss) private var dismiss
  let store: AtlasStore
  let service: AtlasAgentService
  @ViewState private var draft = AtlasAgentGrant()
  @ViewState private var allObjects = false
  @ViewState private var picked: Set<String> = []
  @ViewState private var options: [AtlasStore.AgentObjectOption] = []
  @ViewState private var active = false
  @ViewState private var message = ""
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 9) {
          AtlasArt.compass.resizable().scaledToFit().frame(width: 19, height: 19).accessibilityHidden(true)
          Text("本机 CLI 授权")
            .font(AtlasTypeface.reading.font(21).weight(.medium))
            .foregroundStyle(AtlasPalette.ink)
          Spacer()
          Button("关闭") { dismiss() }
            .buttonStyle(PaperButton(compact: true))
        }
        PaperRule()
        HStack(spacing: 8) {
          Circle()
            .fill(active ? AtlasPalette.sage : AtlasPalette.umber.opacity(0.45))
            .frame(width: 7, height: 7)
          Text(active ? "接口已启用 · 仅本机当前用户" : "接口已关闭")
            .font(AtlasTypeface.reading.font(15).weight(.medium))
            .foregroundStyle(active ? AtlasPalette.sage : AtlasPalette.umber)
        }
        Text("选择此 Atlas 中可读取的对象。启用后，可在终端运行 `atlas workspace list` 查看连接状态。")
          .font(.system(size: 12.5))
          .foregroundStyle(AtlasPalette.ink.opacity(0.84))
        VStack(alignment: .leading, spacing: 8) {
          Toggle("允许读取整个当前 Atlas", isOn: $allObjects)
          if !allObjects {
            ScrollView {
              VStack(alignment: .leading, spacing: 5) {
                ForEach(options) { o in
                  Toggle(
                    o.kind + " · " + o.title,
                    isOn: Binding(
                      get: { picked.contains(o.id) },
                      set: { if $0 { picked.insert(o.id) } else { picked.remove(o.id) } }))
                }
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .padding(8)
            .background(AtlasPalette.paper, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(AtlasPalette.line.opacity(0.38), lineWidth: 0.7)
            }
          }
          Toggle("可按版本读取历史", isOn: $draft.history)
        }
        .padding(12)
        .background(AtlasPalette.paperInset.opacity(0.58), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(AtlasPalette.line.opacity(0.38), lineWidth: 0.75)
        }

        VStack(alignment: .leading, spacing: 7) {
          Text("写操作与整理权限")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(AtlasPalette.umber)
          Toggle("创建灵感", isOn: $draft.create)
          Toggle("提交待审整理提案", isOn: $draft.propose)
          Toggle("应用已授权范围内的批次", isOn: $draft.apply)
          Toggle("回滚批次", isOn: $draft.rollback)
          Toggle("允许批次移除图谱入口", isOn: $draft.removeEntrance)
        }
        .padding(12)
        .background(AtlasPalette.paperInset.opacity(0.58), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(AtlasPalette.line.opacity(0.38), lineWidth: 0.75)
        }

        HStack(spacing: 10) {
          Button(active ? "更新授权并换发令牌" : "启用本机接口") {
            do {
              draft.objects = allObjects ? nil : picked
              try service.authorize(draft, for: store)
              active = true
              message = "授权已保存。"
            } catch { message = error.localizedDescription }
          }
          .buttonStyle(PaperButton(primary: true))
          .accessibilityIdentifier("agent.authorize")
          if active {
            Button("关闭并撤销授权") {
              service.revoke()
              active = false
              message = "原客户端令牌已撤销。"
            }
            .buttonStyle(PaperButton())
            .accessibilityIdentifier("agent.revoke")
          }
        }
        if !message.isEmpty {
          Text(message).font(.system(size: 12.5)).foregroundStyle(AtlasPalette.umber)
        }
      }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 520, minHeight: 520)
    .background(AtlasPalette.paper)
    .foregroundStyle(AtlasPalette.ink)
    .onAppear {
      options = (try? store.agentObjectOptions()) ?? []
      if let saved = service.permissions(for: store) {
        draft = saved
        allObjects = saved.objects == nil
        picked = saved.objects ?? []
        active = true
      }
    }
  }
}
