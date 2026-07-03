import Foundation
import AppKit
import Carbon.HIToolbox
import ScrcpyClient

// MARK: - HID keyboard descriptor

enum HIDKeyboard {
  static let descriptor: Data = Data([
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01,
    0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
    0xC0
  ])

  static func hidKeycode(macKeyCode: UInt16) -> UInt8? {
    switch Int(macKeyCode) {
    case kVK_ANSI_A: return 0x04; case kVK_ANSI_B: return 0x05; case kVK_ANSI_C: return 0x06; case kVK_ANSI_D: return 0x07
    case kVK_ANSI_E: return 0x08; case kVK_ANSI_F: return 0x09; case kVK_ANSI_G: return 0x0A; case kVK_ANSI_H: return 0x0B
    case kVK_ANSI_I: return 0x0C; case kVK_ANSI_J: return 0x0D; case kVK_ANSI_K: return 0x0E; case kVK_ANSI_L: return 0x0F
    case kVK_ANSI_M: return 0x10; case kVK_ANSI_N: return 0x11; case kVK_ANSI_O: return 0x12; case kVK_ANSI_P: return 0x13
    case kVK_ANSI_Q: return 0x14; case kVK_ANSI_R: return 0x15; case kVK_ANSI_S: return 0x16; case kVK_ANSI_T: return 0x17
    case kVK_ANSI_U: return 0x18; case kVK_ANSI_V: return 0x19; case kVK_ANSI_W: return 0x1A; case kVK_ANSI_X: return 0x1B
    case kVK_ANSI_Y: return 0x1C; case kVK_ANSI_Z: return 0x1D
    case kVK_ANSI_1: return 0x1E; case kVK_ANSI_2: return 0x1F; case kVK_ANSI_3: return 0x20; case kVK_ANSI_4: return 0x21
    case kVK_ANSI_5: return 0x22; case kVK_ANSI_6: return 0x23; case kVK_ANSI_7: return 0x24; case kVK_ANSI_8: return 0x25
    case kVK_ANSI_9: return 0x26; case kVK_ANSI_0: return 0x27
    case kVK_Return: return 0x28; case kVK_Escape: return 0x29; case kVK_Delete: return 0x2A
    case kVK_Tab: return 0x2B; case kVK_Space: return 0x2C
    case kVK_ANSI_Minus: return 0x2D; case kVK_ANSI_Equal: return 0x2E
    case kVK_ANSI_LeftBracket: return 0x2F; case kVK_ANSI_RightBracket: return 0x30
    case kVK_ANSI_Backslash: return 0x31; case kVK_ANSI_Semicolon: return 0x33
    case kVK_ANSI_Quote: return 0x34; case kVK_ANSI_Grave: return 0x35
    case kVK_ANSI_Comma: return 0x36; case kVK_ANSI_Period: return 0x37; case kVK_ANSI_Slash: return 0x38
    case kVK_CapsLock: return 0x39
    case kVK_F1: return 0x3A; case kVK_F2: return 0x3B; case kVK_F3: return 0x3C; case kVK_F4: return 0x3D
    case kVK_F5: return 0x3E; case kVK_F6: return 0x3F; case kVK_F7: return 0x40; case kVK_F8: return 0x41
    case kVK_F9: return 0x42; case kVK_F10: return 0x43; case kVK_F11: return 0x44; case kVK_F12: return 0x45
    case kVK_ForwardDelete: return 0x4C
    case kVK_RightArrow: return 0x4F; case kVK_LeftArrow: return 0x50
    case kVK_DownArrow: return 0x51; case kVK_UpArrow: return 0x52
    default: return nil
    }
  }

  static func hidKeycode(ascii char: Character) -> UInt8? {
    guard let ascii = char.asciiValue else { return nil }
    switch ascii {
    case 0x61...0x7A: return ascii - 0x61 + 0x04
    case 0x41...0x5A: return ascii - 0x41 + 0x04
    case 0x31...0x39: return ascii - 0x31 + 0x1E
    case 0x30: return 0x27; case 0x20: return 0x2C; case 0x0A, 0x0D: return 0x28; case 0x09: return 0x2B
    case 0x2D: return 0x2D; case 0x3D: return 0x2E; case 0x5B: return 0x2F; case 0x5D: return 0x30
    case 0x5C: return 0x31; case 0x3B: return 0x33; case 0x27: return 0x34; case 0x60: return 0x35
    case 0x2C: return 0x36; case 0x2E: return 0x37; case 0x2F: return 0x38
    default: return nil
    }
  }

  static func makeReport(modifiers: UInt8, keycodes: [UInt8]) -> Data { var rpt = Data(count: 8); rpt[0] = modifiers; for i in 0..<min(keycodes.count, 6) { rpt[2 + i] = keycodes[i] }; return rpt }
}

// MARK: - UHID Keyboard Manager

@MainActor
final class UHIDKeyboardManager {
  typealias Sink = (ControlMessage) -> Void
  private let sink: Sink; private let deviceId: UInt16 = 42; private var pressedKeys: [UInt8] = []; private var activeModifiers: UInt8 = 0; private var created = false
  init(sink: @escaping Sink) { self.sink = sink }
  func create() { guard !created else { return }; created = true; sink(.uhidCreate(id: deviceId, descriptor: HIDKeyboard.descriptor)) }
  func destroy() { sink(.uhidDestroy(id: deviceId)) }
  func sendKey(_ keycode: UInt8) { var rpt = Data(count: 8); rpt[0] = activeModifiers; rpt[2] = keycode; sink(.uhidInput(id: deviceId, data: rpt)); rpt[2] = 0; sink(.uhidInput(id: deviceId, data: rpt)) }
  @discardableResult func handleKeyDown(with event: NSEvent) -> Bool { guard let hid = HIDKeyboard.hidKeycode(macKeyCode: event.keyCode) else { return false }; if !pressedKeys.contains(hid) { pressedKeys.append(hid) }; syncModifiers(event); flush(); return true }
  @discardableResult func handleKeyUp(with event: NSEvent) -> Bool { guard let hid = HIDKeyboard.hidKeycode(macKeyCode: event.keyCode) else { return false }; pressedKeys.removeAll { $0 == hid }; syncModifiers(event); flush(); return true }
  func handleFlagsChanged(with event: NSEvent) { syncModifiers(event); flush() }
  private func syncModifiers(_ event: NSEvent) { var m: UInt8 = 0; let f = event.modifierFlags; if f.contains(.control) { m |= 0x01 }; if f.contains(.shift) { m |= 0x02 }; if f.contains(.option) { m |= 0x04 }; if f.contains(.command) { m |= 0x08 }; activeModifiers = m }
  private func flush() { sink(.uhidInput(id: deviceId, data: HIDKeyboard.makeReport(modifiers: activeModifiers, keycodes: pressedKeys))) }
}
