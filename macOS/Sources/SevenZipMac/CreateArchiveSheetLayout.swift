import AppKit
import SwiftUI

/// Fits short forms to their content and keeps the actions outside the scrolling region.
struct CreateArchiveSheetLayout<Content: View, Actions: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions
    @State private var contentHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 96
    @State private var availableHeight: CGFloat = 640

    private var height: CGFloat {
        min(max(280, contentHeight + chromeHeight + 2), availableHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "archivebox").foregroundStyle(.blue).accessibilityHidden(true)
                Text("新建压缩包").font(.headline)
                Spacer()
            }.padding(.horizontal, 16).padding(.vertical, 12)
                .background(.bar)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ArchiveSheetChromeHeight.self, value: geometry.size.height)
                    }
                }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ArchiveSheetContentHeight.self, value: geometry.size.height)
                        }
                    }
            }
            Divider()
            HStack(spacing: 8, content: actions)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.bar)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ArchiveSheetChromeHeight.self, value: geometry.size.height)
                    }
                }
        }.frame(width: 580, height: height)
            .onPreferenceChange(ArchiveSheetContentHeight.self) { contentHeight = $0 }
            .onPreferenceChange(ArchiveSheetChromeHeight.self) { chromeHeight = $0 }
            .onAppear(perform: updateAvailableHeight)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in
                updateAvailableHeight()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) {
                _ in
                updateAvailableHeight()
            }
    }

    private func updateAvailableHeight() {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        // Leave room for the presenting window's title bar and screen edges.
        availableHeight = min(640, max(260, (screen?.visibleFrame.height ?? 800) - 80))
    }
}

private struct ArchiveSheetContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ArchiveSheetChromeHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

#Preview {
    CreateArchiveSheetLayout {
        Text("压缩选项")
    } actions: {
        Spacer()
        Button("取消") {}
        Button("创建压缩包") {}.buttonStyle(.borderedProminent)
    }
}
