import AppKit
import ADBKit
import CoreVideo
import CoreMedia
import MirrorEngine
import ScrcpyClient
import SharedModels
import SwiftUI
import os

private let log = Logger(subsystem: "com.droidmirroring.app", category: "mirror")

@MainActor
final class MirrorWindowController: NSWindowController {
  let renderer: MetalFrameRenderer; let session: MirrorSession; let eventView: MirrorEventView; let recorder = ScreenRecorder()
  private var overlayBar: MirrorOverlayBar?; private var currentDeviceSize: CGSize = .zero; private var hasSetInitialFrame = false
  private var isPinned = false; private var isRecording = false; private var isClipboardSyncing = true; private var isScreenOff = false
  private var audioOutput: String { get { UserDefaults.standard.string(forKey: "mirror.audioOutput") ?? "mac" } set { UserDefaults.standard.set(newValue, forKey: "mirror.audioOutput") } }
  private var clipboardBridge: ClipboardBridge?; private let deviceDisplayName: String
  private let adb = ADBClient(); private var screenStatePoller: Timer?; private var autoScreenOffEnabled = false
  private var savedDeviceVolume: Int?; private var chromeRevealed = false; private var chromeHideTimer: Timer?; private var mouseMonitor: Any?
  private var uhidKeyboard: UHIDKeyboardManager?
  private static let bezelInset: CGFloat = 8; private static let bezelCornerRadius: CGFloat = 34; private static let innerCornerRadius: CGFloat = 26; private static let chromeStrip: CGFloat = 32
  var deviceSerial: String?; var isRestarting = false

  init(deviceName: String) throws {
    let renderer = try MetalFrameRenderer(); self.renderer = renderer; self.eventView = MirrorEventView(layer: renderer.layer)
    self.session = MirrorSession { pixelBuffer, pts in renderer.render(pixelBuffer: pixelBuffer) }; self.deviceDisplayName = deviceName.isEmpty ? "Mirror" : deviceName
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = ""; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.titlebarSeparatorStyle = .none
    window.isMovableByWindowBackground = true; window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = true; window.toolbarStyle = .unified; window.contentAspectRatio = NSSize(width: 9, height: 16)
    let screenClip = NSView(); screenClip.wantsLayer = true; screenClip.layer?.cornerRadius = Self.innerCornerRadius; screenClip.layer?.cornerCurve = .continuous; screenClip.layer?.masksToBounds = true; screenClip.layer?.backgroundColor = NSColor.black.cgColor; screenClip.addSubview(eventView); eventView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([eventView.leadingAnchor.constraint(equalTo: screenClip.leadingAnchor), eventView.trailingAnchor.constraint(equalTo: screenClip.trailingAnchor), eventView.topAnchor.constraint(equalTo: screenClip.topAnchor), eventView.bottomAnchor.constraint(equalTo: screenClip.bottomAnchor)])
    let bezel = PhoneBezelView(content: screenClip, inset: Self.bezelInset, cornerRadius: Self.bezelCornerRadius)
    let container = NSView(); container.wantsLayer = true; container.layer?.backgroundColor = NSColor.clear.cgColor; container.addSubview(bezel); bezel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([bezel.leadingAnchor.constraint(equalTo: container.leadingAnchor), bezel.trailingAnchor.constraint(equalTo: container.trailingAnchor), bezel.bottomAnchor.constraint(equalTo: container.bottomAnchor), bezel.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.chromeStrip)])
    window.contentView = container; window.center(); super.init(window: window)
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in self?.saveWindowFrame() }
    NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
      self?.session.paused = !(self?.window?.isVisible == true && self?.window?.occlusionState.contains(.visible) == true)
    }
    let overlay = MirrorOverlayBar(onMore: { [weak self] anchor in self?.showMoreMenu(anchor: anchor) }); self.overlayBar = overlay; container.addSubview(overlay); overlay.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([overlay.centerXAnchor.constraint(equalTo: container.centerXAnchor), overlay.topAnchor.constraint(equalTo: container.topAnchor, constant: 2)])
    renderer.onDimensionsChanged = { [weak self] size in Task { @MainActor in self?.applyDimensions(size) } }; renderer.onFrame = { [weak self] buffer, pts in self?.recorder.append(pixelBuffer: buffer, pts: pts) }
    DispatchQueue.main.async { [weak self] in self?.setChrome(revealed: false, animated: false); window.invalidateShadow() }
    mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .scrollWheel, .keyDown]) { [weak self] event in
      if let self, event.window === self.window { if event.type == .keyDown, event.keyCode == 47, event.modifierFlags.contains(.command) { Task { @MainActor in if let mb = self.overlayBar?.moreButton { self.showMoreMenu(anchor: mb) } }; return nil }; Task { @MainActor in self.handleMouseMoved(event) } }; return event
    }
  }
  required init?(coder: NSCoder) { fatalError() }

  override func close() {
    uhidKeyboard?.destroy(); uhidKeyboard = nil
    screenStatePoller?.invalidate(); screenStatePoller = nil; if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
    chromeHideTimer?.invalidate(); chromeHideTimer = nil; clipboardBridge?.stop(); clipboardBridge = nil
    Task { if recorder.isRecording { await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in recorder.stop { _ in c.resume() } } }; if isScreenOff, let writer = await session.control { try? await writer.send(.setScreenPowerMode(2)) }; if let s = deviceSerial, let v = savedDeviceVolume { try? await adb.shell("media volume --stream 3 --set \(v)", serial: s); savedDeviceVolume = nil }; await session.stop() }; saveWindowFrame(); super.close()
  }

  func bindControl() async {
    guard let writer = await session.control else { return }
    let reader = await session.deviceMessageReader; let initialSize = CGSize(width: Int(await session.dimensions.width), height: Int(await session.dimensions.height))
    let defaults = UserDefaults.standard; let clipboardOn = defaults.object(forKey: "mirror.clipboardSync") as? Bool ?? true; let autoScreenOff = defaults.object(forKey: "mirror.autoScreenOff") as? Bool ?? true
    await MainActor.run {
      self.isClipboardSyncing = clipboardOn; self.autoScreenOffEnabled = autoScreenOff
      self.eventView.controlSink = { msg in Task { try? await writer.send(msg) } }
      if let reader { let bridge = ClipboardBridge(writer: writer, reader: reader); bridge.enabled = clipboardOn; bridge.start(); self.clipboardBridge = bridge }
      self.applyDimensions(initialSize); self.window?.toolbar?.validateVisibleItems()
    }
    if !isRestarting, autoScreenOff { try? await writer.send(.setScreenPowerMode(0)); await MainActor.run { self.isScreenOff = true } }; startScreenStatePoller()
    if !isRestarting { await MainActor.run { self.applyAudioOutput(self.audioOutput) } }; isRestarting = false
    session.paused = false
    // UHID keyboard — create after control channel is fully settled
    try? await Task.sleep(nanoseconds: 300_000_000)
    let km = UHIDKeyboardManager { [weak writer] msg in Task { try? await writer?.send(msg) } }
    await MainActor.run { self.uhidKeyboard = km; self.eventView.uhidKeyboard = km; km.create() }
  }

  @objc private func takeScreenshot() { guard let b = renderer.lastPixelBuffer else { return }; let dir = pictureRoot(); let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"); do { try Screenshotter.savePNG(pixelBuffer: b, to: dir.appendingPathComponent("Screenshot-\(stamp).png")); NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("Screenshot-\(stamp).png")]) } catch { showAlert(error) } }
  @objc private func toggleRecord() { if recorder.isRecording { recorder.stop { [weak self] u in Task { @MainActor in self?.isRecording = false; if let u { NSWorkspace.shared.activateFileViewerSelecting([u]) } } } } else { guard currentDeviceSize.width > 0 else { return }; let dir = movieRoot(); let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"); do { try recorder.start(outputURL: dir.appendingPathComponent("Recording-\(stamp).mp4"), size: currentDeviceSize); isRecording = true } catch { showAlert(error) } } }
  @objc private func togglePin() { isPinned.toggle(); window?.level = isPinned ? .floating : .normal }
  @objc private func wakeDevice() { isScreenOff = false; window?.toolbar?.validateVisibleItems(); Task { if let writer = await session.control { try? await writer.send(.setScreenPowerMode(2)) } } }
  @objc private func sendBack() { Task { if let writer = await session.control { try? await writer.send(.backOrScreenOn(action: .down)); try? await writer.send(.backOrScreenOn(action: .up)) } } }
  @objc private func sendHome() { sendKey(action: .down, code: 3); sendKey(action: .up, code: 3) }
  @objc private func sendRecents() { sendKey(action: .down, code: 187); sendKey(action: .up, code: 187) }
  @objc private func rotateDevice() { Task { if let writer = await session.control { try? await writer.send(.rotateDevice()) } } }
  @objc private func toggleClipboardSync() { isClipboardSyncing.toggle(); clipboardBridge?.enabled = isClipboardSyncing }
  @objc private func cycleAudioOutput() { let n: String = switch audioOutput { case "mac": "phone"; case "phone": "none"; default: "mac" }; audioOutput = n; guard let s = deviceSerial else { return }; isRestarting = true; Task { await SessionCoordinator.shared.restartMirror(for: s) } }
  private func applyAudioOutput(_ mode: String) { switch mode { case "mac": session.resumeAudio(); default: session.pauseAudio() }; guard let s = deviceSerial else { return }; Task { switch mode { case "mac": if savedDeviceVolume == nil { savedDeviceVolume = await fetchDeviceVolume(serial: s) }; await setDeviceVolume(serial: s, level: 0); case "phone": await setDeviceVolume(serial: s, level: savedDeviceVolume ?? 7); savedDeviceVolume = nil; case "none": if savedDeviceVolume == nil { savedDeviceVolume = await fetchDeviceVolume(serial: s) }; await setDeviceVolume(serial: s, level: 0); default: break } } }
  private func fetchDeviceVolume(serial: String) async -> Int? { do { let o = try await adb.shell("media volume --stream 3 --get", serial: serial); if let r = o.range(of: #"(\d+)"#, options: .regularExpression) { return Int(o[r].filter(\.isNumber)) } } catch {}; return nil }
  private func setDeviceVolume(serial: String, level: Int) async { try? await adb.shell("media volume --stream 3 --set \(level)", serial: serial) }
  @objc private func toggleScreenOff() { let tf = !isScreenOff; isScreenOff = tf; window?.toolbar?.validateVisibleItems(); Task { if let writer = await session.control { try? await writer.send(.setScreenPowerMode(tf ? 0 : 2)) } } }
  private func startScreenStatePoller() { screenStatePoller?.invalidate(); screenStatePoller = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in guard let self, let s = self.deviceSerial else { return }; Task.detached { [weak self] in guard let self else { return }; let off = await self.queryDeviceScreenOff(serial: s); await MainActor.run { if self.isScreenOff != off { self.isScreenOff = off; self.window?.toolbar?.validateVisibleItems() } } } } }
  private func queryDeviceScreenOff(serial: String) async -> Bool { do { let o = try await adb.shell("dumpsys power", serial: serial); if let r = o.range(of: "mWakefulness=") { return o[r.upperBound...].prefix { $0.isLetter } != "Awake" } } catch {}; return isScreenOff }
  @objc private func openFiles() { guard let s = deviceSerial else { return }; SessionCoordinator.shared.openFiles(for: Device(id: s, model: session.deviceName, state: .online)) }
  @objc private func openDesktop() { guard let s = deviceSerial else { return }; Task { await SessionCoordinator.shared.openDesktop(for: Device(id: s, model: session.deviceName, androidSDK: 34, state: .online)) } }
  private func sendKey(action: KeyEventAction, code: Int32) { Task { if let writer = await session.control { try? await writer.send(.keycode(code, action: action)) } } }

  private weak var morePopover: NSPopover?
  private func showMoreMenu(anchor: NSView) { if let e = morePopover, e.isShown { e.performClose(nil); return }; let p = NSPopover(); p.behavior = .transient; p.delegate = self; let d: () -> Void = { [weak p] in p?.performClose(nil) }; let panel = MoreActionsPanel(state: MoreActionsPanel.State(isRecording: isRecording, isClipboardSyncing: isClipboardSyncing, isScreenOff: isScreenOff, isPinned: isPinned, audioOutput: audioOutput), onBack: { [weak self] in d(); self?.sendBack() }, onHome: { [weak self] in d(); self?.sendHome() }, onRecents: { [weak self] in d(); self?.sendRecents() }, onFiles: { [weak self] in d(); self?.openFiles() }, onDesktop: { [weak self] in d(); self?.openDesktop() }, onScreenshot: { [weak self] in d(); self?.takeScreenshot() }, onRecord: { [weak self] in d(); self?.toggleRecord() }, onRotate: { [weak self] in d(); self?.rotateDevice() }, onClipboard: { [weak self] in d(); self?.toggleClipboardSync() }, onScreenOff: { [weak self] in d(); self?.toggleScreenOff() }, onWake: { [weak self] in d(); self?.wakeDevice() }, onPin: { [weak self] in d(); self?.togglePin() }, onCycleAudio: { [weak self] in d(); self?.cycleAudioOutput() }); let h = NSHostingController(rootView: panel); p.contentViewController = h; p.contentSize = h.view.fittingSize; morePopover = p; setChrome(revealed: true); chromeHideTimer?.invalidate(); chromeHideTimer = nil; p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY) }

  private func handleMouseMoved(_ event: NSEvent) { guard let window else { return }; if event.locationInWindow.y > window.frame.height - 80 { setChrome(revealed: true) }; scheduleHideChrome() }
  private func setChrome(revealed: Bool, animated: Bool = true) { chromeHideTimer?.invalidate(); chromeHideTimer = nil; if chromeRevealed == revealed { return }; chromeRevealed = revealed; guard let window else { return }; let a: CGFloat = revealed ? 1.0 : 0.0; let btns: [NSButton?] = [window.standardWindowButton(.closeButton), window.standardWindowButton(.miniaturizeButton), window.standardWindowButton(.zoomButton)]; if animated { NSAnimationContext.runAnimationGroup { c in c.duration = 0.18; btns.forEach { $0?.animator().alphaValue = a }; overlayBar?.animator().alphaValue = a } } else { btns.forEach { $0?.alphaValue = a }; overlayBar?.alphaValue = a } }
  private func scheduleHideChrome() { if let p = morePopover, p.isShown { return }; chromeHideTimer?.invalidate(); chromeHideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in Task { @MainActor in self?.setChrome(revealed: false) } } }

  private func saveWindowFrame() { guard let s = deviceSerial, let f = window?.frame else { return }; UserDefaults.standard.set(["x": f.origin.x, "y": f.origin.y, "width": f.size.width, "height": f.size.height], forKey: "mirror.windowFrame.\(s)") }
  private func restoreWindowFrame() { guard let s = deviceSerial, let d = UserDefaults.standard.dictionary(forKey: "mirror.windowFrame.\(s)") as? [String: CGFloat], let x = d["x"], let y = d["y"], let w = d["width"], let h = d["height"], let win = self.window else { return }; let f = NSRect(x: x, y: y, width: w, height: h); guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }) else { return }; win.setFrame(f, display: true); win.invalidateShadow() }

  private func applyDimensions(_ size: CGSize) { guard size.width > 0, size.height > 0 else { return }; let ch = currentDeviceSize != size; currentDeviceSize = size; eventView.deviceDimensions = size; guard let window else { return }; let aspect = aspectRatio(for: size); window.contentAspectRatio = aspect; if !hasSetInitialFrame { hasSetInitialFrame = true; setInitialFrame(deviceSize: size, window: window); restoreWindowFrame(); return }; guard ch else { return }; let of = window.frame; let oc = window.contentRect(forFrameRect: of).size; let oa = max(1, oc.width * oc.height); let sc = sqrt(oa / (aspect.width * aspect.height)); let nc = CGSize(width: aspect.width * sc, height: aspect.height * sc); let nf = window.frameRect(forContentRect: NSRect(origin: .zero, size: nc)); var ff = nf; ff.origin = CGPoint(x: of.midX - ff.width / 2, y: of.midY - ff.height / 2); window.setFrame(ff, display: true, animate: false); window.invalidateShadow() }
  private func setInitialFrame(deviceSize: CGSize, window: NSWindow) { let sv = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero; let target = min(sv.width, sv.height) * 0.6; let ins = Self.bezelInset; let ch = Self.chromeStrip; let sc: CGFloat = (deviceSize.height >= deviceSize.width) ? (target - ch - 2 * ins) / deviceSize.height : (target - 2 * ins) / deviceSize.width; let cs = CGSize(width: deviceSize.width * sc + 2 * ins, height: deviceSize.height * sc + ch + 2 * ins); let fr = window.frameRect(forContentRect: NSRect(origin: .zero, size: cs)); var pos = fr; pos.origin = CGPoint(x: sv.midX - fr.width / 2, y: sv.midY - fr.height / 2); window.setFrame(pos, display: true) }
  private func aspectRatio(for deviceSize: CGSize) -> NSSize { NSSize(width: deviceSize.width + 2 * Self.bezelInset, height: deviceSize.height + Self.chromeStrip + 2 * Self.bezelInset) }
  private func pictureRoot() -> URL { let b = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures"); let d = b.appendingPathComponent("DroidMirroring").appendingPathComponent(deviceDisplayName); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d }
  private func movieRoot() -> URL { let b = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies"); let d = b.appendingPathComponent("DroidMirroring").appendingPathComponent(deviceDisplayName); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d }
  private func showAlert(_ error: Error) { let a = NSAlert(error: error); if let window { a.beginSheetModal(for: window) } else { a.runModal() } }
}

extension MirrorWindowController: NSPopoverDelegate { func popoverDidClose(_ notification: Notification) { scheduleHideChrome() } }

struct MoreActionsPanel: View { struct State { var isRecording: Bool; var isClipboardSyncing: Bool; var isScreenOff: Bool; var isPinned: Bool; var audioOutput: String }
  let state: State; let onBack: () -> Void; let onHome: () -> Void; let onRecents: () -> Void; let onFiles: () -> Void; let onDesktop: () -> Void; let onScreenshot: () -> Void; let onRecord: () -> Void; let onRotate: () -> Void; let onClipboard: () -> Void; let onScreenOff: () -> Void; let onWake: () -> Void; let onPin: () -> Void; let onCycleAudio: () -> Void
  var audioLabel: String { switch state.audioOutput { case "mac": return String(localized: "Mac"); case "phone": return String(localized: "Phone"); default: return String(localized: "Mute") } }
  var audioSymbol: String { switch state.audioOutput { case "mac": return "speaker.wave.3.fill"; case "phone": return "iphone.gen2"; default: return "speaker.slash.fill" } }
  var body: some View { LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) { Tile(symbol: "chevron.backward", label: String(localized: "Back"), action: onBack); Tile(symbol: "circle", label: String(localized: "Home"), action: onHome); Tile(symbol: "square.stack", label: String(localized: "Recents"), action: onRecents); Tile(symbol: "folder", label: String(localized: "Files"), action: onFiles); Tile(symbol: "display", label: String(localized: "Desktop"), action: onDesktop); Tile(symbol: "camera", label: String(localized: "Capture"), action: onScreenshot); Tile(symbol: state.isRecording ? "stop.circle.fill" : "record.circle", label: state.isRecording ? String(localized: "Stop") : String(localized: "Record"), tint: state.isRecording ? .red : nil, action: onRecord); Tile(symbol: "rotate.right", label: String(localized: "Rotate"), action: onRotate); Tile(symbol: state.isClipboardSyncing ? "doc.on.clipboard.fill" : "doc.on.clipboard", label: String(localized: "Clipboard"), tint: state.isClipboardSyncing ? .accentColor : nil, action: onClipboard); Tile(symbol: state.isScreenOff ? "moon.fill" : "moon", label: state.isScreenOff ? String(localized: "Wake") : String(localized: "Sleep"), tint: state.isScreenOff ? .yellow : nil, action: onScreenOff); Tile(symbol: audioSymbol, label: audioLabel, action: onCycleAudio); Tile(symbol: state.isPinned ? "pin.fill" : "pin", label: String(localized: "Pin"), tint: state.isPinned ? .accentColor : nil, action: onPin); Tile(symbol: "power", label: String(localized: "Power"), action: onWake) }.padding(12).frame(width: 340) }
}
private struct Tile: View { let symbol: String; let label: String; var tint: Color? = nil; let action: () -> Void; @State private var hovering = false
  var body: some View { Button(action: action) { VStack(spacing: 4) { Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(tint ?? .primary).frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Color.primary.opacity(0.18) : Color.primary.opacity(0.08))); Text(label).font(.system(size: 10)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).contentShape(Rectangle()) }.buttonStyle(.plain).onHover { hovering = $0 } }
}

final class MirrorOverlayBar: NSView { private let onMore: (NSView) -> Void; private(set) var moreButton: NSButton?; private var hoverTimer: Timer?; private var hoverTracking: NSTrackingArea?
  init(onMore: @escaping (NSView) -> Void) { self.onMore = onMore; super.init(frame: .zero); wantsLayer = true; layer?.cornerCurve = .continuous; let barBg = NSView(); barBg.wantsLayer = true; barBg.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.85).cgColor; barBg.layer?.cornerRadius = 14; barBg.layer?.cornerCurve = .continuous; addSubview(barBg); barBg.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([barBg.leadingAnchor.constraint(equalTo: leadingAnchor), barBg.trailingAnchor.constraint(equalTo: trailingAnchor), barBg.topAnchor.constraint(equalTo: topAnchor), barBg.bottomAnchor.constraint(equalTo: bottomAnchor)]); let symCfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium); let img = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: String(localized: "More"))?.withSymbolConfiguration(symCfg) ?? NSImage(); let btn = NSButton(image: img, target: self, action: #selector(buttonTapped)); btn.isBordered = false; btn.bezelStyle = .smallSquare; btn.contentTintColor = .white; btn.toolTip = String(localized: "More"); btn.imageScaling = .scaleProportionallyDown; btn.setContentHuggingPriority(.required, for: .horizontal); self.moreButton = btn; addSubview(btn); btn.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([btn.centerXAnchor.constraint(equalTo: centerXAnchor), btn.centerYAnchor.constraint(equalTo: centerYAnchor)]); widthAnchor.constraint(equalToConstant: 44).isActive = true; heightAnchor.constraint(equalToConstant: 28).isActive = true }
  required init?(coder: NSCoder) { fatalError() }
  override func updateTrackingAreas() { super.updateTrackingAreas(); if let t = hoverTracking { removeTrackingArea(t) }; let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil); addTrackingArea(t); hoverTracking = t }
  override func mouseEntered(with event: NSEvent) { hoverTimer?.invalidate(); hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in guard let self, let btn = self.moreButton else { return }; Task { @MainActor in self.onMore(btn) } } }
  override func mouseExited(with event: NSEvent) { hoverTimer?.invalidate(); hoverTimer = nil }
  @objc private func buttonTapped() { guard let btn = moreButton else { return }; onMore(btn) }
}

final class PhoneBezelView: NSView { init(content: NSView, inset: CGFloat, cornerRadius: CGFloat) { super.init(frame: .zero); wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor; layer?.cornerRadius = cornerRadius; layer?.cornerCurve = .continuous; layer?.masksToBounds = true; addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset), content.topAnchor.constraint(equalTo: topAnchor, constant: inset), content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)]) }; required init?(coder: NSCoder) { fatalError() } }
