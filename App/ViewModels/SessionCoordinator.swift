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
      for (_, controller) in mirrorWindows { group.addTask { await controller.session.stop() } }
      for (_, controller) in fusionWindows { group.addTask { if let f = await controller.fusion { await f.mirrorSession.stop() } } }
      for (serial, token) in freeformTokens { if let activator = freeformActivators[serial] { group.addTask { await activator.deactivate(token) } } }
    }
    mirrorWindows.removeAll(); fusionWindows.removeAll(); freeformTokens.removeAll(); freeformActivators.removeAll()
  }

  private var trustedKey: String { "mirror.trustedDeviceSerials" }
  private var trusted: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: trustedKey) ?? []) }
    set { UserDefaults.standard.set(Array(newValue), forKey: trustedKey) }
  }
  func trustDevice(_ serial: String) { var s = trusted; s.insert(serial); trusted = s }

  private let adb = ADBClient()
  private var mirrorWindows: [String: MirrorWindowController] = [:]
  private var filesWindows: [String: FilesWindowController] = [:]
  private var fusionWindows: [String: FusionAppWindowController] = [:]
  private var freeformActivators: [String: FreeformActivator] = [:]
  private var freeformTokens: [String: ActivationToken] = [:]
  private var activePanel: [String: (id: Int, width: Int, height: Int, rotation: Int)] = [:]
  private var pollTasks: [String: Task<Void, Never>] = [:]
  private var autoMirroredSerials: Set<String> = []
  private var waitingController: WaitingMirrorWindowController?
  var hasActiveSession: Bool { !mirrorWindows.isEmpty || !fusionWindows.isEmpty }

  func autoMirrorIfNeeded(devices: [Device]) {
    let online = devices.filter { $0.state == .online }
    let onlineSerials = Set(online.map(\.id))
    for serial in Array(mirrorWindows.keys) where !onlineSerials.contains(serial) {
      log.notice("device \(serial) gone — closing Mirror")
      mirrorWindows[serial]?.close(); mirrorWindows.removeValue(forKey: serial)
      pollTasks[serial]?.cancel(); pollTasks.removeValue(forKey: serial)
      activePanel.removeValue(forKey: serial); autoMirroredSerials.remove(serial)
    }
    for serial in Array(filesWindows.keys) where !onlineSerials.contains(serial) {
      filesWindows[serial]?.close(); filesWindows.removeValue(forKey: serial)
    }
    syncWaitingWindow(hasOnlineDevice: !online.isEmpty)
    let autoEnabled = UserDefaults.standard.object(forKey: "mirror.autoOnConnect") as? Bool ?? true
    guard autoEnabled else { return }
    let known = trusted
    for device in online {
      if mirrorWindows[device.id] != nil { continue }
      if autoMirroredSerials.contains(device.id) { continue }
      if !known.contains(device.id) { continue }
      autoMirroredSerials.insert(device.id)
      Task { await startMirror(for: device) }
      break
    }
  }

  func syncWaitingWindow(hasOnlineDevice: Bool) {
    if hasOnlineDevice || !mirrorWindows.isEmpty {
      if let wc = waitingController { wc.window?.orderOut(nil); wc.close(); waitingController = nil }
    } else {
      if waitingController == nil { let wc = WaitingMirrorWindowController(); waitingController = wc; wc.showWindow(nil) }
      else { waitingController?.window?.makeKeyAndOrderFront(nil) }
    }
  }

  func startMirror(for device: Device) async {
    trustDevice(device.id)
    if let existing = mirrorWindows[device.id] { existing.window?.makeKeyAndOrderFront(nil); return }
    let pick = try? await adb.pickActiveDisplay(serial: device.id)
    let displayId = pick?.id ?? 0
    activePanel[device.id] = (id: displayId, width: pick?.width ?? 0, height: pick?.height ?? 0, rotation: pick?.rotation ?? 0)
    var controller: MirrorWindowController?
    do {
      let c = try MirrorWindowController(deviceName: device.model.isEmpty ? device.id : device.model)
      c.deviceSerial = device.id; mirrorWindows[device.id] = c; c.showWindow(nil); controller = c
      try await launchSession(for: device, displayId: displayId, into: c); startActiveDisplayPolling(for: device)
    } catch {
      let isAudioErr = { if case DroidMirroringError.audioUnavailable = error { return true }; return false }()
      let isScrcpyErr = { if case DroidMirroringError.scrcpyProtocol = error { return true }; return false }()
      if (isAudioErr || isScrcpyErr), let c = controller {
        log.warning("retrying without audio for \(device.id)"); await c.session.stop()
        do { try await launchSession(for: device, displayId: displayId, into: c, audioEnabled: false); startActiveDisplayPolling(for: device); return }
        catch { log.error("audio retry failed: \(error)") }
      }
      if !isAudioErr && !isScrcpyErr {
        let e = error.localizedDescription
        if e.contains("display") || e.contains("short read") || e.contains("scrcpy") {
          activePanel.removeValue(forKey: device.id); mirrorWindows[device.id]?.close(); mirrorWindows.removeValue(forKey: device.id)
          do {
            let c2 = try MirrorWindowController(deviceName: device.model.isEmpty ? device.id : device.model)
            c2.deviceSerial = device.id; mirrorWindows[device.id] = c2
            try await launchSession(for: device, displayId: 0, into: c2); startActiveDisplayPolling(for: device); return
          } catch {}
        }
      }
      let alert = NSAlert(); alert.messageText = "Failed to start Mirror"; alert.informativeText = "\(error.localizedDescription)"; alert.addButton(withTitle: "OK"); alert.runModal()
      mirrorWindows[device.id]?.close(); mirrorWindows[device.id] = nil
    }
  }

  // MARK: device disconnect — handles both IP and Android 11+ wireless serials

  func disconnectWirelessDevice(for device: Device) async {
    guard device.transport == .wifi else { return }

    // Clean up all sessions for this device
    if let c = mirrorWindows[device.id] {
      pollTasks[device.id]?.cancel(); pollTasks.removeValue(forKey: device.id)
      activePanel.removeValue(forKey: device.id); autoMirroredSerials.remove(device.id)
      await c.session.stop(); c.close(); mirrorWindows.removeValue(forKey: device.id)
    }
    for key in fusionWindows.keys.filter({ $0.hasPrefix(device.id + "|") }) { fusionWindows[key]?.close(); fusionWindows[key] = nil }
    if let token = freeformTokens.removeValue(forKey: device.id), let a = freeformActivators[device.id] { await a.deactivate(token) }
    filesWindows[device.id]?.close(); filesWindows.removeValue(forKey: device.id)
    autoMirroredSerials.remove(device.id)

    // Disconnect: IP-style (192.168.1.100:5555) or Android 11+ (adb-XXX._adb-tls-connect._tcp)
    let parts = device.id.split(separator: ":").map(String.init)
    if parts.count == 2, let port = Int(parts[1]) {
      let wireless = ResourceLocator.wirelessClient()
      do { try await wireless.disconnect(host: parts[0], port: port); log.notice("disconnected \(device.id)") }
      catch { log.error("disconnect failed for \(device.id): \(error)") }
    } else {
      // Android 11+ wireless serial: adb disconnect <serial>
      await disconnectBySerial(device.id)
    }
  }

  private func disconnectBySerial(_ serial: String) async {
    guard let adbBin = Bundle.main.url(forResource: "adb", withExtension: nil)
            ?? URL(fileURLWithPath: "/usr/local/bin/adb") else { return }
    let p = Process()
    p.executableURL = adbBin
    p.arguments = ["disconnect", serial]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run(); p.waitUntilExit(); log.notice("disconnected \(serial)") }
    catch { log.error("adb disconnect failed for \(serial): \(error)") }
  }

  func openFiles(for device: Device) {
    trustDevice(device.id)
    if let existing = filesWindows[device.id] { existing.window?.makeKeyAndOrderFront(nil); return }
    let c = FilesWindowController(device: device); filesWindows[device.id] = c; c.showWindow(nil)
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: c.window, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in self?.filesWindows.removeValue(forKey: device.id) }
    }
  }

  func appCatalog() -> AppCatalog { AppCatalog(adb: adb) }

  func openDesktop(for device: Device, size: CGSize = CGSize(width: 2560, height: 1440), dpi: Int = 160) async {
    trustDevice(device.id)
    let p = InstalledApp(packageName: "desktop", label: "Desktop", iconPNG: nil)
    let key = fusionKey(serial: device.id, packageName: p.packageName)
    if let e = fusionWindows[key] { e.window?.makeKeyAndOrderFront(nil); return }
    do {
      let a = freeformActivators[device.id] ?? FreeformActivator(adb: adb); freeformActivators[device.id] = a
      if freeformTokens[device.id] == nil { freeformTokens[device.id] = try await a.activate(serial: device.id) }
      let c = try FusionAppWindowController(appLabel: "Desktop — \(device.model.isEmpty ? device.id : device.model)")
      fusionWindows[key] = c; c.showWindow(nil)
      let r = c.renderer; let res = try ResourceLocator.scrcpyResources()
      let s = try await FusionLauncher(adb: adb, scrcpyResources: res).openDesktop(serial: device.id, size: size, dpi: dpi, frameSink: { b, _ in r.render(pixelBuffer: b) })
      await c.attach(s)
      NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: c.window, queue: .main) { [weak self] _ in
        Task { @MainActor in await self?.fusionWindowDidClose(deviceSerial: device.id, packageName: p.packageName) }
      }
    } catch { NSAlert(error: error).runModal(); fusionWindows[key]?.close(); fusionWindows[key] = nil }
  }

  func launchFusionApp(for device: Device, app: InstalledApp, size: CGSize = CGSize(width: 2560, height: 1440), dpi: Int = 160) async {
    trustDevice(device.id)
    let key = fusionKey(serial: device.id, packageName: app.packageName)
    if let e = fusionWindows[key] { e.window?.makeKeyAndOrderFront(nil); return }
    do {
      let a = freeformActivators[device.id] ?? FreeformActivator(adb: adb); freeformActivators[device.id] = a
      if freeformTokens[device.id] == nil { freeformTokens[device.id] = try await a.activate(serial: device.id) }
      let c = try FusionAppWindowController(appLabel: app.label); fusionWindows[key] = c; c.showWindow(nil)
      let r = c.renderer; let res = try ResourceLocator.scrcpyResources()
      let s = try await FusionLauncher(adb: adb, scrcpyResources: res).launch(packageName: app.packageName, serial: device.id, size: size, dpi: dpi, frameSink: { b, _ in r.render(pixelBuffer: b) })
      await c.attach(s)
      NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: c.window, queue: .main) { [weak self] _ in
        Task { @MainActor in await self?.fusionWindowDidClose(deviceSerial: device.id, packageName: app.packageName) }
      }
    } catch { NSAlert(error: error).runModal(); fusionWindows[key]?.close(); fusionWindows[key] = nil }
  }

  private func fusionWindowDidClose(deviceSerial: String, packageName: String) async {
    let key = fusionKey(serial: deviceSerial, packageName: packageName); fusionWindows.removeValue(forKey: key)
    if !fusionWindows.keys.contains(where: { $0.hasPrefix(deviceSerial + "|") }),
       let t = freeformTokens.removeValue(forKey: deviceSerial), let a = freeformActivators[deviceSerial] { await a.deactivate(t) }
  }

  private func fusionKey(serial: String, packageName: String) -> String { "\(serial)|\(packageName)" }

  func stopMirror(for device: Device) async {
    pollTasks[device.id]?.cancel(); pollTasks.removeValue(forKey: device.id); activePanel.removeValue(forKey: device.id)
    for key in fusionWindows.keys.filter({ $0.hasPrefix(device.id + "|") }) { fusionWindows[key]?.close(); fusionWindows[key] = nil }
    if let t = freeformTokens.removeValue(forKey: device.id), let a = freeformActivators[device.id] { await a.deactivate(t) }
    guard let c = mirrorWindows[device.id] else { return }; await c.session.stop(); c.close(); mirrorWindows.removeValue(forKey: device.id)
  }

  private func launchSession(for device: Device, displayId: Int, into controller: MirrorWindowController, audioEnabled: Bool = true) async throws {
    let res = try ResourceLocator.scrcpyResources()
    let launcher = ScrcpyServerLauncher(adb: adb, serial: device.id, resources: res)
    let d = UserDefaults.standard
    let codec = (d.string(forKey: "mirror.codec") ?? "h265")
    let opts = ScrcpyOptions(videoBitRate: ((d.object(forKey: "mirror.bitrate") as? Int) ?? 4) * 1_000_000, maxFps: (d.object(forKey: "mirror.maxFps") as? Int) ?? 30, videoCodec: codec, audioCodec: "opus", audioEnabled: audioEnabled && (d.string(forKey: "mirror.audioOutput") ?? "mac") == "mac", controlEnabled: true, displayId: displayId)
    try await controller.session.start(launcher: launcher, options: opts); await controller.bindControl()
  }

  func restartMirror(for serial: String) async {
    guard let c = mirrorWindows[serial] else { return }
    pollTasks[serial]?.cancel(); pollTasks[serial] = nil
    let did = activePanel[serial]?.id ?? 0
    let dev = Device(id: serial, model: await c.session.deviceName, state: .online)
    await c.session.stop()
    do { try await launchSession(for: dev, displayId: did, into: c); startActiveDisplayPolling(for: dev) }
    catch { c.isRestarting = false; c.close(); mirrorWindows.removeValue(forKey: serial); activePanel.removeValue(forKey: serial) }
  }

  private func startActiveDisplayPolling(for device: Device) {
    pollTasks[device.id]?.cancel()
    pollTasks[device.id] = Task { [weak self] in
      guard let self else { return }; var tick = 0
      while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_500_000_000); tick += 1; await checkActiveDisplay(for: device, tick: tick) }
    }
  }

  func refreshActiveDisplay(for device: Device) async { await checkActiveDisplay(for: device, tick: -1, force: true) }

  private func checkActiveDisplay(for device: Device, tick: Int, force: Bool = false) async {
    guard let c = mirrorWindows[device.id] else { return }
    let displays = (try? await adb.physicalDisplays(serial: device.id)) ?? []
    let r = displays.sorted { a, b in a.state.rank != b.state.rank ? a.state.rank > b.state.rank : a.area > b.area }
    guard let pick = r.first else { return }
    let cur = activePanel[device.id]
    guard force || cur == nil || cur?.id != pick.id || cur?.width != pick.width || cur?.height != pick.height || cur?.rotation != pick.rotation else { return }
    activePanel[device.id] = (id: pick.id, width: pick.width, height: pick.height, rotation: pick.rotation)
    await c.session.stop()
    do { try await launchSession(for: device, displayId: pick.id, into: c) } catch {}
  }

  func cleanupScrcpyServers() async throws {
    let devices = try await adb.listDevices()
    for d in devices where d.state == .online { try await adb.shell("rm -f /data/local/tmp/scrcpy-server*.jar", serial: d.id) }
  }
}

enum ResourceLocator {
  static func scrcpyResources() throws -> ScrcpyServerLauncher.Resources {
    let b = Bundle.main
    guard let jar = b.url(forResource: "scrcpy-server", withExtension: "jar") ?? b.url(forResource: "scrcpy-server-v\(ScrcpyServerVersion.current)", withExtension: "jar")
    else { throw DroidMirroringError.scrcpyProtocol("scrcpy-server.jar not bundled") }
    return .init(serverJar: jar, adbBinary: b.url(forResource: "adb", withExtension: nil) ?? URL(fileURLWithPath: "/usr/local/bin/adb"))
  }
  static func wirelessClient() -> ADBWirelessClient {
    ADBWirelessClient(adbBinary: Bundle.main.url(forResource: "adb", withExtension: nil) ?? URL(fileURLWithPath: "/usr/local/bin/adb"))
  }
}
