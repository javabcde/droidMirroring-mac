import Foundation
import AppKit
import ADBKit
import ScrcpyClient
import MirrorEngine
import FusionEngine
import SharedModels
import os

private let log = Logger(subsystem: "com.droidmirroring.app", category: "coordinator")

@MainActor
final class SessionCoordinator: ObservableObject {
  static let shared = SessionCoordinator()
  func shutdownEverything() async {
    await withTaskGroup(of: Void.self) { group in
      for (_, c) in mirrorWindows { group.addTask { await c.session.stop() } }
      for (_, c) in fusionWindows { group.addTask { if let f = await c.fusion { await f.mirrorSession.stop() } } }
      for (s, t) in freeformTokens { if let a = freeformActivators[s] { group.addTask { await a.deactivate(t) } } }
    }; mirrorWindows.removeAll(); fusionWindows.removeAll(); freeformTokens.removeAll(); freeformActivators.removeAll()
  }
  private var tk: String { "mirror.trustedDeviceSerials" }
  private var trusted: Set<String> { get { Set(UserDefaults.standard.stringArray(forKey: tk) ?? []) } set { UserDefaults.standard.set(Array(newValue), forKey: tk) } }
  func trustDevice(_ s: String) { var x = trusted; x.insert(s); trusted = x }
  private let adb = ADBClient()
  private var mirrorWindows: [String: MirrorWindowController] = [:]
  private var filesWindows: [String: FilesWindowController] = [:]
  private var fusionWindows: [String: FusionAppWindowController] = [:]
  private var freeformActivators: [String: FreeformActivator] = [:]
  private var freeformTokens: [String: ActivationToken] = [:]
  private var activePanel: [String: (id: Int, w: Int, h: Int, rot: Int)] = [:]
  private var pollTasks: [String: Task<Void, Never>] = [:]
  private var am: Set<String> = []
  private var wc: WaitingMirrorWindowController?
  var hasActiveSession: Bool { !mirrorWindows.isEmpty || !fusionWindows.isEmpty }

  func autoMirrorIfNeeded(devices: [Device]) {
    let on = devices.filter { $0.state == .online }; let oss = Set(on.map(\.id))
    for s in Array(mirrorWindows.keys) where !oss.contains(s) { log.notice("device \(s) gone"); mirrorWindows[s]?.close(); mirrorWindows.removeValue(forKey: s); pollTasks[s]?.cancel(); pollTasks.removeValue(forKey: s); activePanel.removeValue(forKey: s); am.remove(s) }
    for s in Array(filesWindows.keys) where !oss.contains(s) { filesWindows[s]?.close(); filesWindows.removeValue(forKey: s) }
    syncWaitingWindow(hasOnlineDevice: !on.isEmpty)
    guard UserDefaults.standard.object(forKey: "mirror.autoOnConnect") as? Bool ?? true else { return }
    let known = trusted
    for d in on { if mirrorWindows[d.id] != nil || am.contains(d.id) || !known.contains(d.id) { continue }; am.insert(d.id); Task { await startMirror(for: d) }; break }
  }

  func syncWaitingWindow(hasOnlineDevice: Bool) {
    if hasOnlineDevice || !mirrorWindows.isEmpty { if let w = wc { w.window?.orderOut(nil); w.close(); wc = nil } }
    else { if wc == nil { let w = WaitingMirrorWindowController(); wc = w; w.showWindow(nil) } else { wc?.window?.makeKeyAndOrderFront(nil) } }
  }

  func startMirror(for d: Device) async {
    trustDevice(d.id)
    if let e = mirrorWindows[d.id] { e.window?.makeKeyAndOrderFront(nil); return }
    let pick = try? await adb.pickActiveDisplay(serial: d.id); let did = pick?.id ?? 0
    activePanel[d.id] = (id: did, w: pick?.width ?? 0, h: pick?.height ?? 0, rot: pick?.rotation ?? 0)
    var c: MirrorWindowController?
    do {
      let mc = try MirrorWindowController(deviceName: d.model.isEmpty ? d.id : d.model); mc.deviceSerial = d.id; mirrorWindows[d.id] = mc; mc.showWindow(nil); c = mc
      try await launchSession(for: d, displayId: did, into: mc); startActiveDisplayPolling(for: d)
    } catch {
      let ae = { if case DroidMirroringError.audioUnavailable = error { return true }; return false }()
      let se = { if case DroidMirroringError.scrcpyProtocol = error { return true }; return false }()
      if (ae || se), let mc = c { log.warning("retry no audio for \(d.id)"); await mc.session.stop(); do { try await launchSession(for: d, displayId: did, into: mc, audioEnabled: false); startActiveDisplayPolling(for: d); return } catch { log.error("retry failed: \(error)") } }
      if !ae && !se { let e = error.localizedDescription; if e.contains("display") || e.contains("short read") || e.contains("scrcpy") { activePanel.removeValue(forKey: d.id); mirrorWindows[d.id]?.close(); mirrorWindows.removeValue(forKey: d.id); do { let m2 = try MirrorWindowController(deviceName: d.model.isEmpty ? d.id : d.model); m2.deviceSerial = d.id; mirrorWindows[d.id] = m2; try await launchSession(for: d, displayId: 0, into: m2); startActiveDisplayPolling(for: d); return } catch {} } }
      NSAlert().then { $0.messageText = "Failed"; $0.informativeText = "\(error.localizedDescription)"; $0.addButton(withTitle: "OK"); $0.runModal() }
      mirrorWindows[d.id]?.close(); mirrorWindows[d.id] = nil
    }
  }

  func disconnectWirelessDevice(for d: Device) async {
    guard d.transport == .wifi else { return }
    if let mc = mirrorWindows[d.id] { pollTasks[d.id]?.cancel(); pollTasks.removeValue(forKey: d.id); activePanel.removeValue(forKey: d.id); am.remove(d.id); await mc.session.stop(); mc.close(); mirrorWindows.removeValue(forKey: d.id) }
    for k in fusionWindows.keys.filter({ $0.hasPrefix(d.id + "|") }) { fusionWindows[k]?.close(); fusionWindows[k] = nil }
    if let t = freeformTokens.removeValue(forKey: d.id), let a = freeformActivators[d.id] { await a.deactivate(t) }
    filesWindows[d.id]?.close(); filesWindows.removeValue(forKey: d.id); am.remove(d.id)
    let parts = d.id.split(separator: ":").map(String.init)
    if parts.count == 2, let p = Int(parts[1]) { do { try await ResourceLocator.wirelessClient().disconnect(host: parts[0], port: p); log.notice("disconnected \(d.id)") } catch { log.error("err: \(error)") } }
    else { let b = Bundle.main.url(forResource: "adb", withExtension: nil) ?? URL(fileURLWithPath: "/usr/local/bin/adb"); let pr = Process(); pr.executableURL = b; pr.arguments = ["disconnect", d.id]; let pp = Pipe(); pr.standardOutput = pp; pr.standardError = pp; do { try pr.run(); pr.waitUntilExit(); log.notice("disconnected \(d.id)") } catch { log.error("err: \(error)") } }
  }

  func openFiles(for d: Device) { trustDevice(d.id); if let e = filesWindows[d.id] { e.window?.makeKeyAndOrderFront(nil); return }; let c = FilesWindowController(device: d); filesWindows[d.id] = c; c.showWindow(nil); NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: c.window, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.filesWindows.removeValue(forKey: d.id) } } }
  func appCatalog() -> AppCatalog { AppCatalog(adb: adb) }
  func openDesktop(for d: Device, size: CGSize = CGSize(width: 2560, height: 1440), dpi: Int = 160) async { trustDevice(d.id); let pk = InstalledApp(packageName: "desktop", label: "Desktop", iconPNG: nil); let k = fk(d.id, pk.packageName); if let e = fusionWindows[k] { e.window?.makeKeyAndOrderFront(nil); return }; do { let a = freeformActivators[d.id] ?? FreeformActivator(adb: adb); freeformActivators[d.id] = a; if freeformTokens[d.id] == nil { freeformTokens[d.id] = try await a.activate(serial: d.id) }; let c = try FusionAppWindowController(appLabel: "Desktop"); fusionWindows[k] = c; c.showWindow(nil); let s = try await FusionLauncher(adb: adb, scrcpyResources: try ResourceLocator.scrcpyResources()).openDesktop(serial: d.id, size: size, dpi: dpi, frameSink: { b, _ in c.renderer.render(pixelBuffer: b) }); await c.attach(s) } catch { NSAlert(error: error).runModal(); fusionWindows[k]?.close(); fusionWindows[k] = nil } }
  func launchFusionApp(for d: Device, app: InstalledApp, size: CGSize = CGSize(width: 2560, height: 1440), dpi: Int = 160) async { trustDevice(d.id); let k = fk(d.id, app.packageName); if let e = fusionWindows[k] { e.window?.makeKeyAndOrderFront(nil); return }; do { let a = freeformActivators[d.id] ?? FreeformActivator(adb: adb); freeformActivators[d.id] = a; if freeformTokens[d.id] == nil { freeformTokens[d.id] = try await a.activate(serial: d.id) }; let c = try FusionAppWindowController(appLabel: app.label); fusionWindows[k] = c; c.showWindow(nil); let s = try await FusionLauncher(adb: adb, scrcpyResources: try ResourceLocator.scrcpyResources()).launch(packageName: app.packageName, serial: d.id, size: size, dpi: dpi, frameSink: { b, _ in c.renderer.render(pixelBuffer: b) }); await c.attach(s) } catch { NSAlert(error: error).runModal(); fusionWindows[k]?.close(); fusionWindows[k] = nil } }
  private func fk(_ s: String, _ p: String) -> String { "\(s)|\(p)" }
  func stopMirror(for d: Device) async { pollTasks[d.id]?.cancel(); pollTasks.removeValue(forKey: d.id); activePanel.removeValue(forKey: d.id); for k in fusionWindows.keys.filter({ $0.hasPrefix(d.id + "|") }) { fusionWindows[k]?.close(); fusionWindows[k] = nil }; if let t = freeformTokens.removeValue(forKey: d.id), let a = freeformActivators[d.id] { await a.deactivate(t) }; guard let c = mirrorWindows[d.id] else { return }; await c.session.stop(); c.close(); mirrorWindows.removeValue(forKey: d.id) }

  private func launchSession(for d: Device, displayId: Int, into c: MirrorWindowController, audioEnabled: Bool = true) async throws {
    let res = try ResourceLocator.scrcpyResources(); let l = ScrcpyServerLauncher(adb: adb, serial: d.id, resources: res); let u = UserDefaults.standard
    let opts = ScrcpyOptions(videoBitRate: ((u.object(forKey: "mirror.bitrate") as? Int) ?? 4) * 1_000_000, maxFps: (u.object(forKey: "mirror.maxFps") as? Int) ?? 30, videoCodec: (u.string(forKey: "mirror.codec") ?? "h265"), audioCodec: "opus", audioEnabled: audioEnabled && (u.string(forKey: "mirror.audioOutput") ?? "mac") == "mac", controlEnabled: true, displayId: displayId)
    try await c.session.start(launcher: l, options: opts); await c.bindControl()
  }

  func restartMirror(for serial: String) async { guard let c = mirrorWindows[serial] else { return }; pollTasks[serial]?.cancel(); pollTasks[serial] = nil; let did = activePanel[serial]?.id ?? 0; let dev = Device(id: serial, model: await c.session.deviceName, state: .online); await c.session.stop(); do { try await launchSession(for: dev, displayId: did, into: c); startActiveDisplayPolling(for: dev) } catch { c.isRestarting = false; c.close(); mirrorWindows.removeValue(forKey: serial); activePanel.removeValue(forKey: serial) } }
  private func startActiveDisplayPolling(for d: Device) { pollTasks[d.id]?.cancel(); pollTasks[d.id] = Task { [weak self] in guard let self else { return }; var t = 0; while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_500_000_000); t += 1; await checkActiveDisplay(for: d, tick: t) } } }
  func refreshActiveDisplay(for d: Device) async { await checkActiveDisplay(for: d, tick: -1, force: true) }
  private func checkActiveDisplay(for d: Device, tick: Int, force: Bool = false) async { guard let c = mirrorWindows[d.id] else { return }; let dis = (try? await adb.physicalDisplays(serial: d.id)) ?? []; let r = dis.sorted { a, b in a.state.rank != b.state.rank ? a.state.rank > b.state.rank : a.area > b.area }; guard let pick = r.first else { return }; let cur = activePanel[d.id]; guard force || cur == nil || cur?.id != pick.id || cur?.w != pick.width || cur?.h != pick.height || cur?.rot != pick.rotation else { return }; activePanel[d.id] = (id: pick.id, w: pick.width, h: pick.height, rot: pick.rotation); await c.session.stop(); do { try await launchSession(for: d, displayId: pick.id, into: c) } catch {} }
  func cleanupScrcpyServers() async throws { for d in try await adb.listDevices() where d.state == .online { try await adb.shell("rm -f /data/local/tmp/scrcpy-server*.jar", serial: d.id) } }
}

enum ResourceLocator {
  static func scrcpyResources() throws -> ScrcpyServerLauncher.Resources { let b = Bundle.main; guard let j = b.url(forResource: "scrcpy-server", withExtension: "jar") ?? b.url(forResource: "scrcpy-server-v\(ScrcpyServerVersion.current)", withExtension: "jar") else { throw DroidMirroringError.scrcpyProtocol("jar missing") }; return .init(serverJar: j, adbBinary: b.url(forResource: "adb", withExtension: nil) ?? URL(fileURLWithPath: "/usr/local/bin/adb")) }
  static func wirelessClient() -> ADBWirelessClient { ADBWirelessClient(adbBinary: Bundle.main.url(forResource: "adb", withExtension: nil) ?? URL(fileURLWithPath: "/usr/local/bin/adb")) }
}
