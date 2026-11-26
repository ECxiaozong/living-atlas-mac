import AppKit
import CoreMedia
import ScreenCaptureKit

/// Only presentation timestamps leave the capture callback. No pixels or audio are retained.
private final class WindowFrameClock: NSObject, SCStreamOutput, SCStreamDelegate {
  let queue = DispatchQueue(label: "LivingAtlas.trial.presentation")
  private var stamps: [Double] = []
  var failed: (() -> Void)?

  func stream(_ stream: SCStream, didStopWithError error: Error) { failed?() }
  func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
      as? [[SCStreamFrameInfo: Any]])?.first, info[.status] as? Int == SCFrameStatus.complete.rawValue else { return }
    stamps.append(buffer.presentationTimeStamp.seconds)
    if stamps.count >= 8192 { stamps.removeFirst(4096) }
  }
  func within(_ start: Double, _ end: Double) -> [Double] {
    queue.sync { stamps.filter { $0 >= start && $0 <= end } }
  }
}

@MainActor final class CanvasTrialDiagnostics: ObservableObject {
  @Published private(set) var active = false
  @Published private(set) var file: URL?
  @Published private(set) var notice: String?
  private var monitor: Any?
  private var stream: SCStream?
  private var clock: WindowFrameClock?
  private var capture: Task<Void, Never>?
  private var idle: DispatchWorkItem?
  private var token = UUID()
  private var started = 0.0
  private let writer = DispatchQueue(label: "LivingAtlas.trial.log")
  private var handle: FileHandle?
  private weak var surface: MapSurface?
  private var gesture: Gesture?

  private struct Gesture {
    let input, area: String
    let start: Double
    var last: Double
    var moved = false
    var actions: Set<String> = []
    var phases: [String] = []
    var precise = false
    var deltaX = 0.0, deltaY = 0.0
    var scrollEvents = 0
  }
  private var now: Double { ProcessInfo.processInfo.systemUptime }

  func start(on surface: MapSurface) {
    guard !active, let window = surface.window else { return }
    let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs/Living Atlas/试用诊断", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent(UUID().uuidString + ".jsonl")
      guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
      else { throw CocoaError(.fileWriteUnknown) }
      handle = try FileHandle(forWritingTo: url)
      file = url
    } catch { notice = "无法保存诊断日志：" + error.localizedDescription; return }
    self.surface = surface
    started = now
    active = true
    notice = nil
    token = UUID()
    write(["event":"start","version":1,"date":Date().ISO8601Format()])
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown,.leftMouseDragged,.leftMouseUp]) { [weak self] event in
      self?.observe(event)
      return event
    }
    let session = token
    let frames = WindowFrameClock()
    clock = frames
    frames.failed = { [weak self] in
      Task { @MainActor in
        guard let self, self.active, self.token == session else { return }
        self.notice = "窗口出帧采样已中断"
        self.write(["event":"frames-unavailable"])
      }
    }
    capture = Task {
      do {
        guard #available(macOS 14.4, *) else { throw CocoaError(.featureUnsupported) }
        let content = try await SCShareableContent.currentProcess
        guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
        else { throw CocoaError(.fileNoSuchFile) }
        let config = SCStreamConfiguration()
        config.width = 160; config.height = 100
        config.showsCursor = false; config.capturesAudio = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        let sampler = SCStream(filter: SCContentFilter(desktopIndependentWindow: own), configuration: config, delegate: frames)
        try sampler.addStreamOutput(frames, type: .screen, sampleHandlerQueue: frames.queue)
        try Task.checkCancellation()
        try await sampler.startCapture()
        guard active, token == session, !Task.isCancelled else { try? await sampler.stopCapture(); return }
        stream = sampler
        write(["event":"frames-ready"])
      } catch {
        guard active, token == session else { return }
        notice = "仅记录手势，窗口出帧采样不可用"
        write(["event":"frames-unavailable","error":(error as NSError).code])
      }
    }
  }

  func action(_ name: String) {
    if gesture != nil { gesture?.actions.insert(name) }
  }

  func observeWheel(_ event: NSEvent) {
    observe(event)
  }

  private func phaseName(_ phase: NSEvent.Phase) -> String {
    if phase.contains(.began) { return "began" }
    if phase.contains(.changed) { return "changed" }
    if phase.contains(.ended) { return "ended" }
    if phase.contains(.cancelled) { return "cancelled" }
    if phase.contains(.mayBegin) { return "may-begin" }
    return "stationary"
  }
  private func observe(_ event: NSEvent) {
    guard active, let surface, let window = surface.window, event.window === window, window.attachedSheet == nil else { return }
    let point = surface.convert(event.locationInWindow, from: nil)
    let stamp = event.timestamp
    switch event.type {
    case .leftMouseDown, .scrollWheel:
      let wheel = event.type == .scrollWheel
      if wheel, gesture?.input == "wheel", !event.phase.contains(.began) || gesture?.phases == ["may-begin"], let last = gesture?.last, stamp-last < 0.25 {
        gesture?.last = stamp
      } else {
        finish()
        guard surface.visibleRect.contains(point) else { return }
        let area = surface.trialArea?(point) ?? "blank"
        gesture = Gesture(input: wheel ? "wheel" : "drag", area: area, start: stamp, last: stamp)
      }
      if wheel {
        gesture?.moved = true
        gesture?.precise = event.hasPreciseScrollingDeltas
        gesture?.deltaX += event.scrollingDeltaX
        gesture?.deltaY += event.scrollingDeltaY
        gesture?.scrollEvents += 1
        let phase = !event.momentumPhase.isEmpty ? "momentum-" + phaseName(event.momentumPhase) :
          (event.phase.isEmpty ? "unphased" : phaseName(event.phase))
        if gesture?.phases.last != phase { gesture?.phases.append(phase) }
        scheduleFinish(after: 0.24)
      }
    case .leftMouseDragged:
      if gesture?.input == "drag" { gesture?.moved = true; gesture?.last = stamp }
    case .leftMouseUp:
      if gesture?.input == "drag" { gesture?.last = stamp; scheduleFinish(after: 0.06) }
    default: break
    }
  }
  private func scheduleFinish(after delay: Double) {
    idle?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.finish() }
    idle = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }
  private func finish() {
    idle?.cancel(); idle = nil
    guard let g = gesture else { return }
    gesture = nil
    guard g.moved else { return }
    let end = min(now, g.last + 0.05)
    let frames = clock?.within(g.start, end) ?? []
    let gaps = zip(frames, frames.dropFirst()).map { (($1-$0)*10000).rounded()/10 }
    write(["event":"gesture","start_ms":Int((g.start-started)*1000),"duration_ms":Int(max(0,g.last-g.start)*1000),
           "input":g.input,"origin":g.area,"actions":g.actions.isEmpty ? ["no-observed-action"] : g.actions.sorted(),
           "precise_scroll":g.precise,"phases":g.phases,"events":g.scrollEvents,"dx":g.deltaX,"dy":g.deltaY,
           "frame_count":frames.count,"frame_intervals_ms":gaps])
  }
  func stop() {
    guard active else { return }
    if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    finish()
    write(["event":"stop"])
    active = false
    capture?.cancel(); capture = nil
    if let stream { Task { try? await stream.stopCapture() } }
    stream = nil
    clock = nil
    let closing = handle
    handle = nil
    writer.async { try? closing?.close() }
  }
  private func write(_ object: [String: Any]) {
    guard let handle else { return }
    let session = token
    writer.async { [weak self] in
      do {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(10)
        try handle.write(contentsOf: data)
      } catch {
        Task { @MainActor in
          guard let self, self.token == session else { return }
          self.notice = "写入试用诊断失败：" + error.localizedDescription
          if self.active { self.stop() }
        }
      }
    }
  }
}
