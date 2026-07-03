import AppKit
import Carbon.HIToolbox
import ScrcpyClient

final class MirrorEventView: NSView, NSTextInputClient {
  var controlSink: ((ControlMessage) -> Void)?
  var deviceDimensions: CGSize = .zero

  // MARK: IME
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
    var t: String?
    if let a = string as? NSAttributedString { t = a.string } else if let s = string as? String { t = s }
    guard let t, !t.isEmpty else { return }
    let c = isComposingIME || markedText != nil || isCJKIMEActive
    if c && t.allSatisfy({ $0.isASCII }) { return }
    markedText = nil; isComposingIME = false
    t.allSatisfy({ $0.isASCII }) ? controlSink?(.text(t)) : controlSink?(.setClipboard(text: t, paste: true))
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    if let a = string as? NSAttributedString { markedText = NSMutableAttributedString(attributedString: a) }
    else if let s = string as? String { markedText = NSMutableAttributedString(string: s) }
    isComposingIME = true
  }
  func unmarkText() { markedText = nil; isComposingIME = false }

  // MARK: init
  private var trackingArea: NSTrackingArea?
  private var currentButtons: MotionButton = []

  init(layer hostedLayer: CALayer) { super.init(frame: .zero); wantsLayer = true; layer = hostedLayer }
  required init?(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }
  override func becomeFirstResponder() -> Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateTrackingAreas() {
    super.updateTrackingAreas(); if let e = trackingArea { removeTrackingArea(e) }
    let a = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
    addTrackingArea(a); trackingArea = a
  }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }

  // MARK: pointer
  override func mouseDown(with e: NSEvent) { currentButtons.insert(.primary); sendTouch(.down, event: e) }
  override func mouseDragged(with e: NSEvent) { sendTouch(.move, event: e) }
  override func mouseUp(with e: NSEvent) { sendTouch(.up, event: e); currentButtons.remove(.primary) }
  override func mouseMoved(with e: NSEvent) { sendTouch(.hoverMove, event: e) }
  override func rightMouseDown(with e: NSEvent) { controlSink?(.backOrScreenOn(action: .down)) }
  override func rightMouseUp(with e: NSEvent) { controlSink?(.backOrScreenOn(action: .up)) }

  // MARK: scroll — accumulate deltas across gesture, send once on gesture end
  private var accDX: Double = 0
  private var accDY: Double = 0
  private var scrollPos: (Int32, Int32)?

  override func scrollWheel(with event: NSEvent) {
    guard let (x, y) = devicePoint(for: event) else { return }
    let fast = event.modifierFlags.contains(.option)
    let d = fast ? 80.0 : 400.0
    accDX += -event.scrollingDeltaX / d
    accDY += event.scrollingDeltaY / d
    scrollPos = (x, y)

    // Only flush on gesture end or momentum end — one scroll cmd per gesture
    if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
      let (sx, sy) = scrollPos ?? (x, y)
      let dx = accDX; let dy = accDY
      accDX = 0; accDY = 0; scrollPos = nil
      guard abs(dx) > 0.003 || abs(dy) > 0.003 else { return }
      controlSink?(.scroll(x: sx, y: sy, screenWidth: UInt16(deviceDimensions.width), screenHeight: UInt16(deviceDimensions.height), hscroll: dx, vscroll: dy, buttons: currentButtons))
    }
  }

  private func sendTouch(_ action: TouchAction, event: NSEvent) {
    guard let (x, y) = devicePoint(for: event) else { return }
    controlSink?(.touch(action: action, x: x, y: y, screenWidth: UInt16(deviceDimensions.width), screenHeight: UInt16(deviceDimensions.height), pressure: action == .up ? 0 : 1, buttons: (action == .hoverMove) ? [] : currentButtons))
  }

  private func devicePoint(for event: NSEvent) -> (Int32, Int32)? {
    guard deviceDimensions.width > 0, deviceDimensions.height > 0 else { return nil }
    let p = convert(event.locationInWindow, from: nil)
    let vw = bounds.width; let vh = bounds.height; guard vw > 0, vh > 0 else { return nil }
    return (max(0, min(Int32(deviceDimensions.width) - 1, Int32((p.x / vw) * deviceDimensions.width))),
            max(0, min(Int32(deviceDimensions.height) - 1, Int32(((vh - p.y) / vh) * deviceDimensions.height))))
  }

  // MARK: keyboard
  private var isCJKIMEActive: Bool {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
    guard let p = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) else { return false }
    let n = (Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String).lowercased()
    return n.contains("pinyin") || n.contains("wubi") || n.contains("cangjie") || n.contains("bopomofo") || n.contains("japanese") || n.contains("korean") || n.contains("简体") || n.contains("繁体") || n.contains("拼音") || n.contains("五笔") || n.contains("仓颉") || n.contains("注音") || n.contains("微信") || n.contains("搜狗") || n.contains("百度")
  }

  override func keyDown(with e: NSEvent) {
    if let kc = MirrorKeyMap.androidKeycode(for: e) {
      if let m = markedText, m.length > 0 { let t = m.string; markedText = nil; isComposingIME = false; t.allSatisfy({ $0.isASCII }) ? controlSink?(.text(t)) : controlSink?(.setClipboard(text: t, paste: true)) }
      controlSink?(.keycode(kc, action: .down, metaState: MirrorKeyMap.metaState(for: e))); return
    }
    let hm = isComposingIME; inputContext?.handleEvent(e)
    if !isComposingIME, !hm, let ch = e.characters, !ch.isEmpty, !ch.allSatisfy({ $0.isASCII }) { controlSink?(.setClipboard(text: ch, paste: true)) }
  }

  override func keyUp(with e: NSEvent) {
    if let kc = MirrorKeyMap.androidKeycode(for: e) { controlSink?(.keycode(kc, action: .up, metaState: MirrorKeyMap.metaState(for: e))) }
  }

  override func flagsChanged(with e: NSEvent) {}

  override func doCommand(by sel: Selector) {
    func commit() { guard let m = markedText, m.length > 0 else { return }; let t = m.string; markedText = nil; isComposingIME = false; t.allSatisfy({ $0.isASCII }) ? controlSink?(.text(t)) : controlSink?(.setClipboard(text: t, paste: true)) }
    if sel == #selector(insertTab(_:)) { commit(); controlSink?(.keycode(61, action: .down)); controlSink?(.keycode(61, action: .up)) }
    else if sel == #selector(insertNewline(_:)) { commit(); controlSink?(.keycode(66, action: .down)); controlSink?(.keycode(66, action: .up)) }
    else if sel == #selector(deleteBackward(_:)) { if let m = markedText, let l = markedText?.length, l > 0 { markedText?.deleteCharacters(in: NSRange(location: l-1, length: 1)); if markedText?.length == 0 { markedText = nil; isComposingIME = false } } else { controlSink?(.keycode(67, action: .down)); controlSink?(.keycode(67, action: .up)) } }
    else if sel == #selector(cancelOperation(_:)) { unmarkText() }
    else if sel == #selector(insertText(_:replacementRange:)) || sel == Selector("paste:") {}
    else { super.doCommand(by: sel) }
  }
}
