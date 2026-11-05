import CoreGraphics
import Foundation

// Prints the CGWindowID of the frontmost normal-layer window owned by an app.
let owner = CommandLine.arguments.dropFirst().first ?? "Notesy"
let options: CGWindowListOption = [.optionOnScreenOnly]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows {
    // Notesy is the name of the app bundle/executable.
    let owner = window[kCGWindowOwnerName as String] as? String
    print("Owner: \(owner ?? "nil")")
    if owner?.contains("Canvas") == true,
          let number = window[kCGWindowNumber as String] as? Int {
        print(number)
        exit(0)
    }
}
exit(1)
