import SwiftUI
import AppKit
import DeviceDiscovery
import SharedModels

struct MenuBarContent: View {
  @EnvironmentObject var monitor: DeviceMonitor
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  @State private var isDeploying = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header; Divider()
      if monitor.devices.contains(where: { $0.state == .online }) { deviceList } else { emptyState }
      Divider()
      Button { NSApp.activate(ignoringOtherApps: true); openWindow(id: WindowID.pairing) } label: { Label("Add Wireless Device…", systemImage: "wifi.router") }.buttonStyle(.plain)
      Button {
        guard !isDeploying else { return }
        isDeploying = true
        Task {
          defer { isDeploying = false }
          for device in monitor.devices where device.state == .online && device.transport == .usb {
            do {
              try await SessionCoordinator.shared.deployAgent(to: device.id)
              await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "安装完成"
                alert.informativeText = "已在 \(device.model.isEmpty ? device.id : device.model) 上安装 Agent。打开手机上的 DroidMirror Agent，打开开关即可。"
                alert.alertStyle = .informational
                alert.runModal()
              }
            } catch {
              await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "安装失败"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
              }
            }
          }
        }
      } label: {
        if isDeploying {
          Label("正在安装 Agent…", systemImage: "arrow.down.circle.dotted")
        } else {
          Label("在手机上安装 Agent…", systemImage: "iphone.badge.plus")
        }
      }
      .buttonStyle(.plain)
      .disabled(isDeploying)
      Button { openSettings() } label: { Label("Settings…", systemImage: "gearshape") }.buttonStyle(.plain)
      Divider()
      Button(role: .destructive) { NSApp.terminate(nil) } label: { Label("Quit macDros", systemImage: "power") }.buttonStyle(.plain).keyboardShortcut("q", modifiers: [.command])
    }
    .padding(.horizontal, 12).padding(.vertical, 10).frame(width: 280)
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "iphone.gen3").font(.title3).foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 1) {
        Text("macDros").font(.headline)
        let count = monitor.devices.filter { $0.state == .online }.count
        Text(count == 0 ? "no devices" : "\(count) device\(count == 1 ? "" : "s") online")
          .font(.caption2.monospaced()).foregroundStyle(.secondary)
      }
    }
  }

  private var deviceList: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(monitor.devices.filter { $0.state == .online }) { device in MenuDeviceRow(device: device) }
    }
  }

  private var emptyState: some View {
    HStack(spacing: 8) {
      Image(systemName: "iphone.slash").foregroundStyle(.secondary)
      Text("No device connected").font(.callout).foregroundStyle(.secondary)
    }.padding(.vertical, 4)
  }
}

private struct MenuDeviceRow: View {
  let device: Device
  @State private var showMenu = false
  @State private var hoverTask: Task<Void, Never>?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: device.transport == .wifi ? "wifi" : "cable.connector").foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 1) {
        Text(device.model.isEmpty ? device.id : device.model).font(.callout)
        Text("\(device.manufacturer.isEmpty ? "Android" : device.manufacturer) · SDK \(device.androidSDK)").font(.caption2.monospaced()).foregroundStyle(.secondary)
      }
      Spacer()
      if device.transport == .wifi {
        Button {
          Task { await SessionCoordinator.shared.disconnectWirelessDevice(for: device) }
        } label: {
          Image(systemName: "eject.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain).fixedSize()
        .help("Disconnect")
      }
      Button { showMenu.toggle() } label: { Image(systemName: "ellipsis.circle") }.buttonStyle(.plain).fixedSize()
        .onHover { hovering in
          hoverTask?.cancel()
          if hovering { hoverTask = Task { try? await Task.sleep(nanoseconds: 300_000_000); if !Task.isCancelled { await MainActor.run { showMenu = true } } } }
          else { hoverTask = Task { try? await Task.sleep(nanoseconds: 400_000_000); if !Task.isCancelled { await MainActor.run { showMenu = false } } } }
        }
        .popover(isPresented: $showMenu, arrowEdge: .trailing) {
          VStack(alignment: .leading, spacing: 4) {
            Button { showMenu = false; Task { await SessionCoordinator.shared.startMirror(for: device) } } label: { Label("Mirror", systemImage: "rectangle.on.rectangle") }.buttonStyle(.plain)
            Button { showMenu = false; SessionCoordinator.shared.openFiles(for: device) } label: { Label("Files", systemImage: "folder") }.buttonStyle(.plain)
            if device.supportsFreeform { Button { showMenu = false; Task { await SessionCoordinator.shared.openDesktop(for: device) } } label: { Label("Desktop", systemImage: "display") }.buttonStyle(.plain) }
          }
          .padding(10)
          .onHover { hovering in if !hovering { hoverTask = Task { try? await Task.sleep(nanoseconds: 300_000_000); if !Task.isCancelled { await MainActor.run { showMenu = false } } } } }
        }
    }
    .padding(.horizontal, 8).padding(.vertical, 6)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    .onTapGesture(count: 2) { Task { await SessionCoordinator.shared.startMirror(for: device) } }
  }
}
