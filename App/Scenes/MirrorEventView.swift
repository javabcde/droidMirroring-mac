import AppKit
import Carbon.HIToolbox
import ScrcpyClient

final class MirrorEventView: NSView, NSTextInputClient {
  var controlSink: ((ControlMessage) -> Void)?
  var deviceDimensions: CGSize = .zero
  var uhidKeyboard: UHIDKeyboardManager?

  private var markedText: NSMutableAttributedString?
  private var isComposingIME = false
  private var _currentFrame: NSRect = .zero
  func selectedRange() -> NSRange { markedText.map { NSRange(location: $0.length, length: 0) } ?? NSRange() }
  func markedRange() -> NSRange { markedText?.length ?? 0 > 0 ? NSRange(location: 0, length: markedText!.length) : NSRange() }
  func hasMarkedText() -> Bool { markedText?.length ?? 0 > 0 }
  func attributedSubstring(forProposedRange r: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func firstRect(forCharacterRange r: NSRange, actualRange: NSRangePointer?) -> NSRect { window?.convertToScreen(convert(_currentFrame, to: nil)) ?? .zero }
  func characterIndex(for p: NSPoint) -> Int { 0 }
  func insertText(_ string: Any, replacementRange: NSRange) {
    var t: String?; if let a = string as? NSAttributedString { t = a.string } else if let s = string as? String { t = s }
    guard let t, !t.isEmpty else { return }
    if (isComposingIME || markedText != nil || isCJKIMEActive) && t.allSatisfy({ $0.isASCII }) { return }
    markedText = nil; isComposingIME = false
    t.allSatisfy({ $0.isASCII }) ? { for ch in t { if let hk = HIDKeyboard.hidKeycode(ascii: ch) { uhidKeyboard?.sendKey(hk) } } }() : controlSink?(.setClipboard(text: t, paste: true))
  }
  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) { if let a = string as? NSAttributedString { markedText = NSMutableAttributedString(attributedString: a) } else if let s = string as? String { markedText = NSMutableAttributedString(string: s) }; isComposingIME = true }
  func unmarkText() { markedText = nil; isComposingIME = false }

  private var trackingArea: NSTrackingArea?; private var currentButtons: MotionButton = []
  init(layer hostedLayer: CALayer) { super.init(frame: .zero); wantsLayer = true; layer = hostedLayer }
  required init?(coder: NSCoder) { fatalError() }
  override var acceptsFirstResponder: Bool { true }; override func becomeFirstResponder() -> Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func updateTrackingAreas() { super.updateTrackingAreas(); if let e = trackingArea { removeTrackingArea(e) }; let a = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil); addTrackingArea(a); trackingArea = a }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }

  private var dragStartDevice: (Int32, Int32)?; private var dragMoved = false
  override func mouseDown(with e: NSEvent) { currentButtons.insert(.primary); dragMoved = false; if let pt = devicePoint(for: e) { dragStartDevice = pt }; sendTouch(.down, event: e) }
  override func mouseDragged(with e: NSEvent) { dragMoved = true; sendTouch(.move, event: e) }
  override func mouseUp(with e: NSEvent) {
    if dragMoved, let start = dragStartDevice, let cur = devicePoint(for: e) { let h = Int32(deviceDimensions.height); let dy = (cur.1 - start.1) * 2; if start.1 > h * 2 / 3 && cur.1 < start.1 && abs(cur.1 - start.1) > 8 { sendTouchAt(.move, x: max(0, min(Int32(deviceDimensions.width) - 1, cur.0)), y: max(0, min(h - 1, cur.1 + dy))) } }
    sendTouch(.up, event: e); currentButtons.remove(.primary); dragStartDevice = nil; dragMoved = false
  }
  override func mouseMoved(with e: NSEvent) { sendTouch(.hoverMove, event: e) }
  override func rightMouseDown(with e: NSEvent) { controlSink?(.backOrScreenOn(action: .down)) }
  override func rightMouseUp(with e: NSEvent) { controlSink?(.backOrScreenOn(action: .up)) }

  private var accDX: Double = 0; private var accDY: Double = 0; private var scrollOrigin: (Int32, Int32)?
  override func scrollWheel(with event: NSEvent) {
    if !event.momentumPhase.isEmpty && event.momentumPhase != .began { return }
    guard let (x, y) = devicePoint(for: event) else { return }
    if scrollOrigin == nil || event.phase == .began { scrollOrigin = (x, y) }
    let d = event.modifierFlags.contains(.option) ? 80.0 : 400.0
    accDX += -event.scrollingDeltaX / d; accDY += event.scrollingDeltaY / d
    if event.phase == .ended || event.phase == .cancelled {
      let o = scrollOrigin ?? (x, y); let dx = accDX; let dy = accDY; accDX = 0; accDY = 0; scrollOrigin = nil
      guard abs(dx) > 0.003 || abs(dy) > 0.003 else { return }
      controlSink?(.scroll(x: o.0, y: o.1, screenWidth: UInt16(deviceDimensions.width), screenHeight: UInt16(deviceDimensions.height), hscroll: dx, vscroll: dy, buttons: currentButtons))
    }
  }

  private func sendTouch(_ action: TouchAction, event: NSEvent) { guard let (x, y) = devicePoint(for: event) else { return }; sendTouchAt(action, x: x, y: y) }
  private func sendTouchAt(_ action: TouchAction, x: Int32, y: Int32) { controlSink?(.touch(action: action, x: x, y: y, screenWidth: UInt16(deviceDimensions.width), screenHeight: UInt16(deviceDimensions.height), pressure: action == .up ? 0 : 1, buttons: (action == .hoverMove) ? [] : currentButtons)) }
  private func devicePoint(for event: NSEvent) -> (Int32, Int32)? {
    guard deviceDimensions.width > 0, deviceDimensions.height > 0 else { return nil }
    let p = convert(event.locationInWindow, from: nil); let vw = bounds.width; let vh = bounds.height; guard vw > 0, vh > 0 else { return nil }
    return (max(0, min(Int32(deviceDimensions.width) - 1, Int32((p.x / vw) * deviceDimensions.width))), max(0, min(Int32(deviceDimensions.height) - 1, Int32(((vh - p.y) / vh) * deviceDimensions.height))))
  }

  private var isCJKIMEActive: Bool {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
    guard let p = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) else { return false }
    let n = (Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String).lowercased()
    return n.contains("pinyin") || n.contains("wubi") || n.contains("cangjie") || n.contains("bopomofo") || n.contains("japanese") || n.contains("korean") || n.contains("简体") || n.contains("繁体") || n.contains("拼音") || n.contains("五笔") || n.contains("仓颉") || n.contains("注音") || n.contains("微信") || n.contains("搜狗") || n.contains("百度")
  }
  override func keyDown(with e: NSEvent) {
    if uhidKeyboard?.handleKeyDown(with: e) == true { return }
    if let kc = MirrorKeyMap.androidKeycode(for: e) {
      if let m = markedText, m.length > 0 { let t = m.string; markedText = nil; isComposingIME = false; for ch in t { if let hk = HIDKeyboard.hidKeycode(ascii: ch) { uhidKeyboard?.sendKey(hk) } } }
      else { controlSink?(.keycode(kc, action: .down, metaState: MirrorKeyMap.metaState(for: e))) }; return
    }
    let hm = isComposingIME; inputContext?.handleEvent(e)
    if !isComposingIME, !hm, let ch = e.characters, !ch.isEmpty, !ch.allSatisfy({ $0.isASCII }) { controlSink?(.setClipboard(text: ch, paste: true)) }
  }
  override func keyUp(with e: NSEvent) { if uhidKeyboard?.handleKeyUp(with: e) == true { return }; if let kc = MirrorKeyMap.androidKeycode(for: e) { controlSink?(.keycode(kc, action: .up, metaState: MirrorKeyMap.metaState(for: e))) } }
  override func flagsChanged(with e: NSEvent) { uhidKeyboard?.handleFlagsChanged(with: e) }
  override func doCommand(by sel: Selector) {
    func commit() { guard let m = markedText, m.length > 0 else { return }; markedText = nil; isComposingIME = false; for ch in m.string { if let hk = HIDKeyboard.hidKeycode(ascii: ch) { uhidKeyboard?.sendKey(hk) } } }
    if sel == #selector(insertTab(_:)) { commit(); uhidKeyboard?.sendKey(0x2B) }
    else if sel == #selector(insertNewline(_:)) { commit(); uhidKeyboard?.sendKey(0x28) }
    else if sel == #selector(deleteBackward(_:)) { if let l = markedText?.length, l > 0 { markedText?.deleteCharacters(in: NSRange(location: l-1, length: 1)); if markedText?.length == 0 { markedText = nil; isComposingIME = false } } else { uhidKeyboard?.sendKey(0x2A) } }
    else if sel == #selector(cancelOperation(_:)) { unmarkText() }
    else if sel == #selector(insertText(_:replacementRange:)) || sel == Selector("paste:") {}
    else { super.doCommand(by: sel) }
  }
}
