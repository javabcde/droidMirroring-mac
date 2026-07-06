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
    if t.allSatisfy({ $0.isASCII }) { if let u = uhidKeyboard { for ch in t { if let hk = HIDKeyboard.hidKeycode(ascii: ch) { u.sendKey(hk) } } } else { controlSink?(.setClipboard(text: t, paste: true)) } }
    else { controlSink?(.setClipboard(text: t, paste: true)) }
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

  private var dragStartDevice: (Int32, Int32)?; private var dragMoved = false; private var dragStartTimestamp: TimeInterval = 0
  override func mouseDown(with e: NSEvent) { currentButtons.insert(.primary); dragMoved = false; if let pt = devicePoint(for: e) { dragStartDevice = pt }; dragStartTimestamp = e.timestamp; sendTouch(.down, event: e) }
  override func mouseDragged(with e: NSEvent) { dragMoved = true; sendTouch(.move, event: e) }
  override func mouseUp(with e: NSEvent) {
    if dragMoved, let start = dragStartDevice, let cur = devicePoint(for: e) {
      let dy = (cur.1 - start.1) * 3; let dx = (cur.0 - start.0) * 3
      let moved = abs(cur.1 - start.1) + abs(cur.0 - start.0)
      let elapsed = max(0.001, e.timestamp - dragStartTimestamp)
      if moved > 8 && (abs(dy) > 2 || abs(dx) > 2) {
        let h = Int32(deviceDimensions.height); let w = Int32(deviceDimensions.width)
        let steps = max(3, min(12, Int(moved / 20)))
        let endX = max(0, min(w - 1, cur.0 + dx)); let endY = max(0, min(h - 1, cur.1 + dy))
        for i in 1...steps { let t = Double(i) / Double(steps); let ix = Int32(Double(cur.0) + Double(endX - cur.0) * t); let iy = Int32(Double(cur.1) + Double(endY - cur.1) * t); sendTouchAt(.move, x: ix, y: iy) }
      }
    }
    sendTouch(.up, event: e); currentButtons.remove(.primary); dragStartDevice = nil; dragMoved = false
  }
  override func mouseMoved(with e: NSEvent) { sendTouch(.hoverMove, event: e) }
  override func rightMouseDown(with e: NSEvent) { controlSink?(.backOrScreenOn(action: .down)) }
  override func rightMouseUp(with e: NSEvent) { controlSink?(.backOrScreenOn(action: .up)) }

  private var scrollOrigin: (Int32, Int32)?; private var hScrollActive = false; private var hScrollLastX: Int32 = 0; private var hScrollTotal: Int32 = 0; private var hScrollMax: Double = 0
  override func scrollWheel(with event: NSEvent) {
    guard let (x, y) = devicePoint(for: event) else { return }
    let hasH = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
    if hasH {
      if event.phase == .began { hScrollActive = true; hScrollLastX = x; hScrollTotal = 0; hScrollMax = 0 }
      if hScrollActive {
        let scaled = Int32(event.scrollingDeltaX * Double(deviceDimensions.width) / max(1, bounds.width) * 4.0)
        hScrollLastX = max(0, min(Int32(deviceDimensions.width) - 1, hScrollLastX + scaled))
        hScrollTotal += scaled; hScrollMax = max(hScrollMax, abs(Double(scaled)))
        if event.phase == .began { sendTouchAt(.down, x: x, y: y) }
        sendTouchAt(.move, x: hScrollLastX, y: y)
        if event.phase == .ended || event.phase == .cancelled {
          let flingDir: Double = hScrollTotal > 0 ? 1.0 : (hScrollTotal < 0 ? -1.0 : 0)
          let baseDist = Double(deviceDimensions.width) * 0.35
          let flingDist = Int32(flingDir * max(baseDist, hScrollMax * 25))
          let flingSteps = max(8, min(20, Int(abs(flingDist) / 15)))
          for i in 1...flingSteps { let t = Double(i) / Double(flingSteps); let fx = max(0, min(Int32(deviceDimensions.width) - 1, hScrollLastX + Int32(Double(flingDist) * t))); sendTouchAt(.move, x: fx, y: y) }
          sendTouchAt(.up, x: max(0, min(Int32(deviceDimensions.width) - 1, hScrollLastX + flingDist)), y: y); hScrollActive = false
        }
      }
      return
    }
    if event.phase == .began || (scrollOrigin == nil && event.momentumPhase == .began) { scrollOrigin = (x, y) }
    let d: Double
    if event.hasPreciseScrollingDeltas { d = event.modifierFlags.contains(.option) ? 1500.0 : 800.0 }
    else { d = 10.0 }
    var dx = -event.scrollingDeltaX / d; var dy = event.scrollingDeltaY / d
    dx = max(-0.05, min(0.05, dx)); dy = max(-0.05, min(0.05, dy))
    if abs(dy) > 0.0001 {
      let o = scrollOrigin ?? (x, y)
      controlSink?(.scroll(x: o.0, y: o.1, screenWidth: UInt16(deviceDimensions.width), screenHeight: UInt16(deviceDimensions.height), hscroll: 0, vscroll: dy, buttons: currentButtons))
    }
    if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended { scrollOrigin = nil }
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
      if let m = markedText, m.length > 0 { let t = m.string; markedText = nil; isComposingIME = false; if let u = uhidKeyboard { for ch in t { if let hk = HIDKeyboard.hidKeycode(ascii: ch) { u.sendKey(hk) } } } else { controlSink?(.setClipboard(text: t, paste: true)) } }
      else { controlSink?(.keycode(kc, action: .down, metaState: MirrorKeyMap.metaState(for: e))) }; return
    }
    let hm = isComposingIME; inputContext?.handleEvent(e)
    if !isComposingIME, !hm, let ch = e.characters, !ch.isEmpty, !ch.allSatisfy({ $0.isASCII }) { controlSink?(.setClipboard(text: ch, paste: true)) }
  }
  override func keyUp(with e: NSEvent) { if uhidKeyboard?.handleKeyUp(with: e) == true { return }; if let kc = MirrorKeyMap.androidKeycode(for: e) { controlSink?(.keycode(kc, action: .up, metaState: MirrorKeyMap.metaState(for: e))) } }
  override func flagsChanged(with e: NSEvent) { uhidKeyboard?.handleFlagsChanged(with: e) }
  override func doCommand(by sel: Selector) {
    func commit() { guard let m = markedText, m.length > 0 else { return }; let t = m.string; markedText = nil; isComposingIME = false; if t.allSatisfy({ $0.isASCII }) { if let u = uhidKeyboard { for ch in t { if let hk = HIDKeyboard.hidKeycode(ascii: ch) { u.sendKey(hk) } } } else { controlSink?(.setClipboard(text: t, paste: true)) } } else { controlSink?(.setClipboard(text: t, paste: true)) } }
    if sel == #selector(insertTab(_:)) { commit(); if let u = uhidKeyboard { u.sendKey(0x2B) } else { controlSink?(.setClipboard(text: "\t", paste: true)) } }
    else if sel == #selector(insertNewline(_:)) { commit(); if let u = uhidKeyboard { u.sendKey(0x28) } else { controlSink?(.setClipboard(text: "\n", paste: true)) } }
    else if sel == #selector(deleteBackward(_:)) { if let l = markedText?.length, l > 0 { markedText?.deleteCharacters(in: NSRange(location: l-1, length: 1)); if markedText?.length == 0 { markedText = nil; isComposingIME = false } } else { if let u = uhidKeyboard { u.sendKey(0x2A) } } }
    else if sel == #selector(cancelOperation(_:)) { unmarkText() }
    else if sel == #selector(insertText(_:replacementRange:)) || sel == Selector("paste:") {}
    else { super.doCommand(by: sel) }
  }
}
