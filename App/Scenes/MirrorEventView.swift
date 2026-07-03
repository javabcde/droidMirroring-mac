import AppKit
import Carbon.HIToolbox
import ScrcpyClient


/// NSView that owns the Metal layer AND captures pointer/key events for the mirror session.
/// Coordinates are translated from view-local points to device pixels and sent on
/// the scrcpy control socket via `controlSink`.
///
/// Conforms to `NSTextInputClient` to support IME input (Chinese, Japanese, etc.).
final class MirrorEventView: NSView, NSTextInputClient {
  /// Closure that ships a ControlMessage. Set by MirrorWindowController once the
  /// session's control writer is ready.
  var controlSink: ((ControlMessage) -> Void)?

  /// Device dimensions in pixels (width, height). Updated when the renderer reports
  /// a new pixel-buffer size (rotation / foldable unfold).
  var deviceDimensions: CGSize = .zero

  // MARK: - NSTextInputClient (IME support)

  private var markedText: NSMutableAttributedString?
  private var isComposingIME = false
  private var _currentFrame: NSRect = .zero

  func selectedRange() -> NSRange {
    guard let markedText else { return NSRange(location: 0, length: 0) }
    return NSRange(location: markedText.length, length: 0)
  }

  func markedRange() -> NSRange {
    guard let text = markedText, text.length > 0 else { return NSRange() }
    return NSRange(location: 0, length: text.length)
  }

  func hasMarkedText() -> Bool { markedText?.length ?? 0 > 0 }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    window?.convertToScreen(convert(_currentFrame, to: nil)) ?? .zero
  }

  func characterIndex(for point: NSPoint) -> Int { 0 }

  func insertText(_ string: Any, replacementRange: NSRange) {
    var textToInsert: String?
    if let attrStr = string as? NSAttributedString { textToInsert = attrStr.string }
    else if let str = string as? String { textToInsert = str }
    guard let textToInsert, !textToInsert.isEmpty else { return }
    let viaFlag = self.isComposingIME; let viaMarked = self.markedText != nil; let viaSource = isCJKIMEActive
    let isComposing = viaFlag || viaMarked || viaSource
    if isComposing && textToInsert.allSatisfy({ $0.isASCII }) { return }
    markedText = nil; isComposingIME = false
    if textToInsert.allSatisfy({ $0.isASCII }) { controlSink?(.text(textToInsert)) }
    else { controlSink?(.setClipboard(text: textToInsert, paste: true)) }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    if let attrStr = string as? NSAttributedString { markedText = NSMutableAttributedString(attributedString: attrStr) }
    else if let str = string as? String { markedText = NSMutableAttributedString(string: str) }
    isComposingIME = true
  }

  func unmarkText() { markedText = nil; isComposingIME = false }

  // MARK: - init / focus / cursor

  private var trackingArea: NSTrackingArea?
  private var currentButtons: MotionButton = []

  init(layer hostedLayer: CALayer) { super.init(frame: .zero); wantsLayer = true; layer = hostedLayer }
  required init?(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }
  override func becomeFirstResponder() -> Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let existing = trackingArea { removeTrackingArea(existing) }
    let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
    addTrackingArea(area); trackingArea = area
  }

  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }

  // MARK: pointer

  override func mouseDown(with event: NSEvent) { currentButtons.insert(.primary); sendTouch(.down, event: event) }
  override func mouseDragged(with event: NSEvent) { sendTouch(.move, event: event) }
  override func mouseUp(with event: NSEvent) { sendTouch(.up, event: event); currentButtons.remove(.primary) }
  override func mouseMoved(with event: NSEvent) { sendTouch(.hoverMove, event: event) }
  override func rightMouseDown(with event: NSEvent) { controlSink?(.backOrScreenOn(action: .down)) }
  override func rightMouseUp(with event: NSEvent) { controlSink?(.backOrScreenOn(action: .up)) }

  override func scrollWheel(with event: NSEvent) {
    guard let (x, y) = devicePoint(for: event) else { return }
    // scrcpy scroll convention: hscroll > 0 = finger moves RIGHT, vscroll > 0 = finger moves UP.
    // Mac natural scrolling: two-finger LEFT → deltaX negative, two-finger UP → deltaY positive.
    // X: negate to match (deltaX negative → hscroll positive → finger RIGHT → content RIGHT ✓)
    // Y: pass through (deltaY positive → vscroll positive → finger UP → content UP ✓)
    // Divisor 400: one full two-finger trackpad swipe ≈ one full finger swipe on device.
    // Hold ⌥ (Option) for fast scroll: divisor 80 for ~5x speed (three-finger equivalent).
    let fast = event.modifierFlags.contains(.option)
    let divisor = fast ? 80.0 : 400.0
    let dx = -event.scrollingDeltaX / divisor
    let dy = event.scrollingDeltaY / divisor
    guard abs(dx) > 0.003 || abs(dy) > 0.003 else { return }
    controlSink?(.scroll(
      x: x, y: y,
      screenWidth: UInt16(deviceDimensions.width),
      screenHeight: UInt16(deviceDimensions.height),
      hscroll: dx, vscroll: dy,
      buttons: currentButtons
    ))
  }

  private func sendTouch(_ action: TouchAction, event: NSEvent) {
    guard let (x, y) = devicePoint(for: event) else { return }
    let buttons: MotionButton = (action == .hoverMove) ? [] : currentButtons
    controlSink?(.touch(action: action, x: x, y: y, screenWidth: UInt16(deviceDimensions.width), screenHeight: UInt16(deviceDimensions.height), pressure: action == .up ? 0 : 1, buttons: buttons))
  }

  private func devicePoint(for event: NSEvent) -> (Int32, Int32)? {
    guard deviceDimensions.width > 0, deviceDimensions.height > 0 else { return nil }
    let p = convert(event.locationInWindow, from: nil)
    let viewW = bounds.width; let viewH = bounds.height
    guard viewW > 0, viewH > 0 else { return nil }
    let devX = Int32((p.x / viewW) * deviceDimensions.width)
    let devY = Int32(((viewH - p.y) / viewH) * deviceDimensions.height)
    return (max(0, min(Int32(deviceDimensions.width) - 1, devX)), max(0, min(Int32(deviceDimensions.height) - 1, devY)))
  }

  // MARK: keyboard

  private var isCJKIMEActive: Bool {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
    guard let namePtr = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) else { return false }
    let name = Unmanaged<CFString>.fromOpaque(namePtr).takeUnretainedValue() as String
    let lower = name.lowercased()
    return lower.contains("pinyin") || lower.contains("wubi") || lower.contains("cangjie")
        || lower.contains("bopomofo") || lower.contains("japanese") || lower.contains("korean")
        || lower.contains("简体") || lower.contains("繁体") || lower.contains("拼音")
        || lower.contains("五笔") || lower.contains("仓颉") || lower.contains("注音")
        || lower.contains("微信") || lower.contains("搜狗") || lower.contains("百度")
  }

  override func keyDown(with event: NSEvent) {
    if let keycode = MirrorKeyMap.androidKeycode(for: event) {
      if let marked = markedText, marked.length > 0 {
        let text = marked.string; markedText = nil; isComposingIME = false
        if text.allSatisfy({ $0.isASCII }) { controlSink?(.text(text)) }
        else { controlSink?(.setClipboard(text: text, paste: true)) }
      }
      controlSink?(.keycode(keycode, action: .down, metaState: MirrorKeyMap.metaState(for: event)))
      return
    }
    let hadMarkedText = isComposingIME; let cjkActive = isCJKIMEActive
    inputContext?.handleEvent(event)
    if !isComposingIME, !hadMarkedText, let chars = event.characters, !chars.isEmpty, !chars.allSatisfy({ $0.isASCII }) {
      controlSink?(.setClipboard(text: chars, paste: true))
    }
  }

  override func keyUp(with event: NSEvent) {
    if let keycode = MirrorKeyMap.androidKeycode(for: event) {
      controlSink?(.keycode(keycode, action: .up, metaState: MirrorKeyMap.metaState(for: event)))
    }
  }

  override func flagsChanged(with event: NSEvent) {}

  override func doCommand(by selector: Selector) {
    func commitMarkedText() {
      guard let marked = markedText, marked.length > 0 else { return }
      let text = marked.string; markedText = nil; isComposingIME = false
      if text.allSatisfy({ $0.isASCII }) { controlSink?(.text(text)) }
      else { controlSink?(.setClipboard(text: text, paste: true)) }
    }
    if selector == #selector(insertTab(_:)) { commitMarkedText(); controlSink?(.keycode(61, action: .down)); controlSink?(.keycode(61, action: .up)) }
    else if selector == #selector(insertNewline(_:)) { commitMarkedText(); controlSink?(.keycode(66, action: .down)); controlSink?(.keycode(66, action: .up)) }
    else if selector == #selector(deleteBackward(_:)) {
      if markedText != nil, let len = markedText?.length, len > 0 { markedText?.deleteCharacters(in: NSRange(location: len - 1, length: 1)); if markedText?.length == 0 { markedText = nil; isComposingIME = false } }
      else { controlSink?(.keycode(67, action: .down)); controlSink?(.keycode(67, action: .up)) }
    }
    else if selector == #selector(cancelOperation(_:)) { unmarkText() }
    else if selector == #selector(insertText(_:replacementRange:)) || selector == Selector("paste:") {}
    else { super.doCommand(by: selector) }
  }
}
