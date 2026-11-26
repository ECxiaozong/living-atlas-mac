import AtlasCore
import SwiftUI

@main
struct LivingAtlasApp: App {
  @StateObject private var session = Session(defaults: launchPreferences())

  private static func launchPreferences() -> UserDefaults {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["LIVING_ATLAS_TRIAL_HOME"] ?? env["CFFIXED_USER_HOME"], path.hasPrefix("/") else { return .standard }
    do {
      return try TrialPreferences.open(at: URL(fileURLWithPath: path),
        inheritModelFrom: env["LIVING_ATLAS_TRIAL_MODEL_HOME"].map { URL(fileURLWithPath: $0) })
    } catch { fatalError("无法打开试用偏好：\(error.localizedDescription)") }
  }
  private var initialWindow: CGSize {
    let target = CGSize(width: 1360, height: 900)
    guard let screen = NSScreen.main else { return target }
    return CGSize(
      width: min(target.width, screen.visibleFrame.width),
      height: min(target.height, screen.visibleFrame.height))
  }
  var body: some Scene {
    Window("Living Atlas", id: "workspace") {
      Workspace().environmentObject(session).defaultAppStorage(session.defaults).preferredColorScheme(.light)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in session.agentAccess.attach(store:nil) }
        .background {
          ProjectCloseObserver { session.saveRecoveryPointsOnClose() }
          AtlasWindowChrome()
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 760, minHeight: 550)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentMinSize)
    .defaultSize(width: initialWindow.width, height: initialWindow.height)
    .commands {
      CanvasHistoryCommands()
      CommandGroup(replacing: .help) { Button("画布操作帮助") { session.canvasHelp = true } }
      CommandMenu("画布") {
        Button("噗噗助手…") { session.assistantShown = true }
          .disabled(session.store == nil)
          .keyboardShortcut("k", modifiers: [.command, .option])
        Button("命令面板…") {
          if session.area != .overview { session.area = .overview }
          session.commandPalette.toggle()
        }
        .disabled(session.store == nil)
        .keyboardShortcut("k", modifiers: .command)
        Divider()
        Button("画布操作帮助") { session.canvasHelp = true }
        Divider()
        SmoothCaretMenuItem().defaultAppStorage(session.defaults)
      }
      CommandGroup(replacing: .newItem) {
        Button("新建 Atlas…") { session.choose(new: true) }.keyboardShortcut("n")
        Button("打开 Atlas…") { session.choose(new: false) }.keyboardShortcut("o")
      }
      CommandGroup(replacing: .appSettings) {
        Button("本机 CLI 授权…") { session.agentSettings = true }.disabled(session.store == nil).keyboardShortcut(",", modifiers:[.command,.option])
        Button("模型设置…") { session.settings = true }.keyboardShortcut(",")
      }
    }
  }
}

private struct SmoothCaretMenuItem: View {
  @AppStorage("writing.smoothCaret") private var enabled = true
  var body: some View { Toggle("平滑输入光标（笔记与追问）", isOn: $enabled) }
}
