// Posts synthetic mouse events for UI probing in CI. Usage: swift click.swift x y [dx dy]
import CoreGraphics
import Foundation

let args = CommandLine.arguments.dropFirst().compactMap(Double.init)
let start = CGPoint(x: args[0], y: args[1])
let end = CGPoint(x: args[0] + (args.count > 2 ? args[2] : 0), y: args[1] + (args.count > 3 ? args[3] : 0))
func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(30_000)
}
post(.mouseMoved, start)
usleep(150_000)
post(.leftMouseDown, start)
if end != start { post(.leftMouseDragged, end) }
post(.leftMouseUp, end)
