import AppKit

@MainActor
func promptPDFPassword(_ title: String) -> String? {
  let sheet = NSAlert()
  sheet.messageText = "解锁 " + title
  sheet.informativeText = "密码只用于本次打开的 Atlas。"
  let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
  input.placeholderString = "PDF 密码"
  sheet.accessoryView = input
  sheet.addButton(withTitle: "解锁")
  sheet.addButton(withTitle: "取消")
  sheet.window.initialFirstResponder = input
  return sheet.runModal() == .alertFirstButtonReturn ? input.stringValue : nil
}
