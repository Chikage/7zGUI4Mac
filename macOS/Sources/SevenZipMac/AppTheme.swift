import AppKit
import SwiftUI

enum AppTheme {
    // Fixed action fill maintains > 4.5:1 contrast with white labels in both
    // appearances. Surrounding surfaces and text use adaptive system colors.
    static let action = Color(nsColor: NSColor(srgbRed: 0.071, green: 0.353, blue: 0.741, alpha: 1))
}
