import Foundation
import SharedModels

public enum ControlMessageType: UInt8, Sendable {
  case injectKeycode = 0; case injectText = 1; case injectTouchEvent = 2
  case injectScrollEvent = 3; case backOrScreenOn = 4; case expandNotificationPanel = 5
  case expandSettingsPanel = 6; case collapsePanels = 7; case getClipboard = 8
  case setClipboard = 9; case setScreenPowerMode = 10; case rotateDevice = 11
  case uhidCreate = 12; case uhidInput = 13; case openHardKeyboardSettings = 14
  case startApp = 15; case resetVideo = 16
}

public enum KeyEventAction: UInt8, Sendable { case down = 0; case up = 1 }

public enum TouchAction: UInt8, Sendable { case down = 0; case up = 1; case move = 2; case cancel = 3; case outside = 4; case pointerDown = 5; case pointerUp = 6; case hoverMove = 7; case scroll = 8; case hoverEnter = 9; case hoverExit = 10; case buttonPress = 11; case buttonRelease = 12 }

public struct MotionButton: OptionSet, Sendable { public let rawValue: UInt32; public init(rawValue: UInt32) { self.rawValue = rawValue }; public static let primary = MotionButton(rawValue: 1 << 0); public static let secondary = MotionButton(rawValue: 1 << 1); public static let tertiary = MotionButton(rawValue: 1 << 2); public static let back = MotionButton(rawValue: 1 << 3); public static let forward = MotionButton(rawValue: 1 << 4) }

public struct ControlMessage: Sendable { public let type: ControlMessageType; public let payload: Data; public func serialize() -> Data { var d = Data([type.rawValue]); d.append(payload); return d } }

public extension ControlMessage {
  static func touch(action: TouchAction, x: Int32, y: Int32, screenWidth: UInt16, screenHeight: UInt16, pressure: Double = 1.0, pointerId: UInt64 = 0xFFFF_FFFF_FFFF_FFFF, actionButton: MotionButton = .primary, buttons: MotionButton = []) -> ControlMessage { var p = Data(); p.appendByte(action.rawValue); p.appendBE(UInt64: pointerId); p.appendBE(UInt32: UInt32(bitPattern: x)); p.appendBE(UInt32: UInt32(bitPattern: y)); p.appendBE(UInt16: screenWidth); p.appendBE(UInt16: screenHeight); p.appendBE(UInt16: UInt16(max(0, min(1, pressure)) * Double(UInt16.max))); p.appendBE(UInt32: actionButton.rawValue); p.appendBE(UInt32: buttons.rawValue); return ControlMessage(type: .injectTouchEvent, payload: p) }
  static func scroll(x: Int32, y: Int32, screenWidth: UInt16, screenHeight: UInt16, hscroll: Double, vscroll: Double, buttons: MotionButton = []) -> ControlMessage { var p = Data(); p.appendBE(UInt32: UInt32(bitPattern: x)); p.appendBE(UInt32: UInt32(bitPattern: y)); p.appendBE(UInt16: screenWidth); p.appendBE(UInt16: screenHeight); p.appendBE(Int16: Int16(max(-1, min(1, hscroll)) * Double(Int16.max))); p.appendBE(Int16: Int16(max(-1, min(1, vscroll)) * Double(Int16.max))); p.appendBE(UInt32: buttons.rawValue); return ControlMessage(type: .injectScrollEvent, payload: p) }
  static func keycode(_ keycode: Int32, action: KeyEventAction, repeatCount: UInt32 = 0, metaState: UInt32 = 0) -> ControlMessage { var p = Data(); p.appendByte(action.rawValue); p.appendBE(UInt32: UInt32(bitPattern: keycode)); p.appendBE(UInt32: repeatCount); p.appendBE(UInt32: metaState); return ControlMessage(type: .injectKeycode, payload: p) }
  static func text(_ string: String) -> ControlMessage { var p = Data(); let b = Data(string.utf8); p.appendBE(UInt32: UInt32(b.count)); p.append(b); return ControlMessage(type: .injectText, payload: p) }
  static func backOrScreenOn(action: KeyEventAction) -> ControlMessage { ControlMessage(type: .backOrScreenOn, payload: Data([action.rawValue])) }
  static func getClipboard(copyKey: UInt8 = 0) -> ControlMessage { ControlMessage(type: .getClipboard, payload: Data([copyKey])) }
  static func setClipboard(text: String, sequence: UInt64 = 0, paste: Bool = false) -> ControlMessage { var p = Data(); p.appendBE(UInt64: sequence); p.appendByte(paste ? 1 : 0); let b = Data(text.utf8); p.appendBE(UInt32: UInt32(b.count)); p.append(b); return ControlMessage(type: .setClipboard, payload: p) }
  static func rotateDevice() -> ControlMessage { ControlMessage(type: .rotateDevice, payload: Data()) }
  static func setScreenPowerMode(_ mode: UInt8) -> ControlMessage { ControlMessage(type: .setScreenPowerMode, payload: Data([mode])) }

  // UHID
  /// scrcpy wire format: [id:2][vendor_id:2][product_id:2][name_len:1][name:N][desc_len:2][desc:N]
  /// scrcpy sends vendor_id=0, product_id=0, name=NULL (length 0)
  static func uhidCreate(id: UInt16, descriptor: Data) -> ControlMessage {
    var p = Data()
    p.appendBE(UInt16: id)
    p.appendBE(UInt16: 0)  // vendor_id
    p.appendBE(UInt16: 0)  // product_id
    p.append(0 as UInt8)   // name length = 0 (NULL)
    p.appendBE(UInt16: UInt16(descriptor.count))
    p.append(descriptor)
    return ControlMessage(type: .uhidCreate, payload: p)
  }
  /// scrcpy wire format: [id:2][size:2][data:size] — size field prevents TCP
  /// buffer merge from corrupting multi-message reads on the server side
  static func uhidInput(id: UInt16, data: Data) -> ControlMessage { var p = Data(); p.appendBE(UInt16: id); p.appendBE(UInt16: UInt16(data.count)); p.append(data); return ControlMessage(type: .uhidInput, payload: p) }
  /// UHID device cleaned up when control socket closes — no explicit destroy message in scrcpy protocol
  static func uhidDestroy(id: UInt16) -> ControlMessage { ControlMessage(type: .uhidCreate, payload: Data()) }
}

private extension Data {
  mutating func appendByte(_ v: UInt8) { append(v) }
  mutating func appendBE(UInt16 v: UInt16) { var b = v.bigEndian; Swift.withUnsafeBytes(of: &b) { append(contentsOf: $0) } }
  mutating func appendBE(UInt32 v: UInt32) { var b = v.bigEndian; Swift.withUnsafeBytes(of: &b) { append(contentsOf: $0) } }
  mutating func appendBE(UInt64 v: UInt64) { var b = v.bigEndian; Swift.withUnsafeBytes(of: &b) { append(contentsOf: $0) } }
  mutating func appendBE(Int16 v: Int16) { var b = v.bigEndian; Swift.withUnsafeBytes(of: &b) { append(contentsOf: $0) } }
}
