import CoreGraphics
import Foundation

// Drags the pointer from one screen point to another in small steps so AppKit
// sees a real mouseDragged sequence: drag.swift <x1> <y1> <x2> <y2>
guard CommandLine.arguments.count == 5,
      let x1 = Double(CommandLine.arguments[1]), let y1 = Double(CommandLine.arguments[2]),
      let x2 = Double(CommandLine.arguments[3]), let y2 = Double(CommandLine.arguments[4]) else {
    FileHandle.standardError.write(Data("usage: drag <x1> <y1> <x2> <y2>\n".utf8))
    exit(2)
}
let source = CGEventSource(stateID: .hidSystemState)
let start = CGPoint(x: x1, y: y1)
let end = CGPoint(x: x2, y: y2)

CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(80_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(120_000)

let steps = 24
for step in 1...steps {
    let t = Double(step) / Double(steps)
    let point = CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(16_000)
}
usleep(80_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
