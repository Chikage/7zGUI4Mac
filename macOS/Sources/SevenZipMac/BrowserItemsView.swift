import AppKit
import ArchiveCore
import SwiftUI

enum BrowserLayout: String, CaseIterable, Identifiable {
    case large, medium, small, list, details
    var id: String { rawValue }
    var title: String {
        switch self {
        case .large: "大图标"
        case .medium: "中图标"
        case .small: "小图标"
        case .list: "列表"
        case .details: "详细信息"
        }
    }
    var symbol: String {
        switch self {
        case .large: "square.grid.2x2"
        case .medium: "square.grid.3x3"
        case .small: "square.grid.4x3.fill"
        case .list: "list.bullet"
        case .details: "list.bullet.rectangle"
        }
    }
    var iconSize: CGFloat {
        switch self {
        case .large: 64
        case .medium: 40
        case .small: 20
        case .list, .details: 18
        }
    }
    var cellWidth: CGFloat {
        switch self {
        case .large: 128
        case .medium: 104
        default: 200
        }
    }
}

struct BrowserViewMenu: View {
    @AppStorage("browserLayout") private var layout: BrowserLayout = .details
    var body: some View {
        Menu {
            Picker("浏览方式", selection: $layout) {
                ForEach(BrowserLayout.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(layout.title, systemImage: layout.symbol)
        }
        .help("切换文件浏览布局").fixedSize()
    }
}

struct BrowserItemsView<MenuContent: View>: View {
    let entries: [BrowserEntry]
    @Binding var selection: Set<String>
    let searchActive: Bool
    let open: (Set<String>) -> Void
    var preview: ((Set<String>) -> Bool)? = nil
    var cutPaths: Set<String> = []
    @ViewBuilder let menu: (Set<String>) -> MenuContent
    @AppStorage("browserLayout") private var layout: BrowserLayout = .details
    @AppStorage("browserShowsCheckboxes") private var showsCheckboxes = false
    @State private var sortOrder = [KeyPathComparator(\BrowserEntry.name)]
    @State private var anchor: String?
    @State private var cursor: String?
    @State private var mouseInteraction = BrowserMouseInteraction()
    @FocusState private var gridFocused: Bool

    private var rows: [BrowserEntry] {
        entries.sorted(using: sortOrder).sorted { $0.isDirectory && !$1.isDirectory }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if layout != .details {
                    Menu {
                        Button("名称") { sortOrder = [KeyPathComparator(\BrowserEntry.name)] }
                        Button("大小") { sortOrder = [KeyPathComparator(\BrowserEntry.size)] }
                        Button("类型") { sortOrder = [KeyPathComparator(\BrowserEntry.kind)] }
                        Button("修改日期") { sortOrder = [KeyPathComparator(\BrowserEntry.modified, order: .reverse)] }
                        Divider()
                        Button("反转排序") {
                            sortOrder = sortOrder.map {
                                var comparator = $0
                                comparator.order = comparator.order == .forward ? .reverse : .forward
                                return comparator
                            }
                        }
                    } label: {
                        Label("排序", systemImage: "arrow.up.arrow.down")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Button("全选") { selection = Set(entries.map(\.id)) }
                    .disabled(entries.isEmpty).help("选择当前显示的所有项目")
                Button("反选") { selection = Set(entries.map(\.id)).subtracting(selection) }
                    .disabled(entries.isEmpty).help("反转当前显示项目的选中状态")
                Button("取消选择") { selection = [] }
                    .disabled(selection.isEmpty)
                Spacer(minLength: 12)
                Toggle("显示复选框", isOn: $showsCheckboxes)
                    .toggleStyle(.checkbox).fixedSize()
            }.controlSize(.small).padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            Group {
                switch layout {
                case .details: details
                case .list: list
                default: grid
                }
            }
            .background {
                BrowserMouseMonitor(interaction: mouseInteraction) { id, event in
                    if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
                        if !selection.contains(id) {
                            select(id, modifiers: [])
                        }
                    } else if layout != .details && layout != .list && event.clickCount == 1 {
                        gridFocused = true
                        select(id, modifiers: event.modifierFlags)
                    }
                }
            }
            .onKeyPress(.space, phases: .down) { press in
                guard press.modifiers.isEmpty, preview?(selection) == true else { return .ignored }
                return .handled
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(
                        searchActive ? "没有匹配的文件" : "文件夹为空",
                        systemImage: searchActive ? "magnifyingglass" : "folder",
                        description: Text(searchActive ? "尝试其他名称。" : "此位置没有可显示的项目。")
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: entries) { _, value in
            selection.formIntersection(Set(value.map(\.id)))
            if let anchor, !value.contains(where: { $0.id == anchor }) { self.anchor = nil }
        }
    }

    private var details: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("名称", value: \.name) { entry in
                rowLabel(entry, size: 18, showsPath: searchActive)
                    .padding(.vertical, 4)
                    .background { mouseTarget(entry) }
            }.width(min: 180, ideal: 300)
            TableColumn("修改日期", value: \.modified) { entry in
                Text(entry.modified.isEmpty ? "—" : String(entry.modified.prefix(16)))
                    .foregroundStyle(.secondary).monospacedDigit()
            }.width(min: 120, ideal: 140, max: 170)
            TableColumn("类型", value: \.kind) { entry in
                Text(entry.kind).foregroundStyle(.secondary)
            }.width(min: 70, ideal: 85, max: 130)
            TableColumn("大小", value: \.size) { entry in
                Text(entry.isDirectory ? "—" : formatBytes(entry.size))
                    .foregroundStyle(.secondary).monospacedDigit()
            }.width(min: 70, ideal: 85, max: 115)
        }
        .contextMenu(forSelectionType: String.self, menu: menu, primaryAction: open)
    }

    private var list: some View {
        List(rows, selection: $selection) { entry in
            rowLabel(entry, size: 18, showsPath: searchActive)
                .padding(.vertical, 3).tag(entry.id)
                .background { mouseTarget(entry) }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self, menu: menu, primaryAction: open)
    }

    private var grid: some View {
        GeometryReader { geometry in
            let columns = max(1, Int((geometry.size.width - 32 + 8) / (layout.cellWidth + 8)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: layout.cellWidth), spacing: 8)], spacing: 8) {
                        ForEach(rows) { entry in
                            gridCell(entry)
                                .opacity(cutPaths.contains(entry.id) ? 0.5 : 1)
                                .id(entry.id)
                                .background { mouseTarget(entry) }
                                .onTapGesture(count: 2) {
                                    selection = [entry.id]
                                    open([entry.id])
                                }
                                .contextMenu { menu(selection.contains(entry.id) ? selection : [entry.id]) }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel(entry.name)
                                .accessibilityAddTraits(selection.contains(entry.id) ? .isSelected : [])
                                .accessibilityAction {
                                    gridFocused = true
                                    select(entry.id, modifiers: [])
                                }
                                .accessibilityAction(named: Text("打开")) {
                                    selection = [entry.id]
                                    open([entry.id])
                                }
                        }
                    }.padding(16)
                    Color.clear.frame(maxWidth: .infinity, minHeight: 40)
                        .contentShape(Rectangle()).onTapGesture {
                            selection = []
                            gridFocused = true
                        }
                }
                .contextMenu { menu([]) }
                .focusable().focused($gridFocused)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    guard !rows.isEmpty else { return .ignored }
                    let current = rows.firstIndex { $0.id == cursor } ?? -1
                    let offset: Int
                    switch press.key {
                    case .leftArrow: offset = -1
                    case .rightArrow: offset = 1
                    case .upArrow: offset = -columns
                    case .downArrow: offset = columns
                    default: return .ignored
                    }
                    let index = min(rows.count - 1, max(0, current < 0 ? 0 : current + offset))
                    let id = rows[index].id
                    var modifiers: NSEvent.ModifierFlags = []
                    if press.modifiers.contains(.shift) { modifiers.insert(.shift) }
                    if press.modifiers.contains(.command) { modifiers.insert(.command) }
                    select(id, modifiers: modifiers)
                    proxy.scrollTo(id)
                    return .handled
                }
                .onKeyPress(.return) {
                    open(selection)
                    return .handled
                }
                .onKeyPress(.escape) {
                    selection = []
                    return .handled
                }
                .onKeyPress(characters: CharacterSet(charactersIn: "a")) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    selection = Set(rows.map(\.id))
                    return .handled
                }
            }
        }
    }

    private func mouseTarget(_ entry: BrowserEntry) -> some View {
        BrowserMouseTarget(
            id: entry.id, usesTableRow: layout == .details || layout == .list,
            interaction: mouseInteraction)
    }

    private func gridCell(_ entry: BrowserEntry) -> some View {
        Group {
            if layout == .small {
                rowLabel(entry, size: layout.iconSize, showsPath: false)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } else {
                VStack(spacing: 8) {
                    BrowserEntryIcon(entry: entry, size: layout.iconSize)
                    Text(entry.name).font(.body).lineLimit(2).truncationMode(.middle)
                        .multilineTextAlignment(.center).frame(height: 36, alignment: .top)
                    if entry.isEncrypted { Image(systemName: "lock.fill").accessibilityLabel("已加密") }
                }.frame(maxWidth: .infinity).padding(12)
                    .overlay(alignment: .topLeading) {
                        if showsCheckboxes { checkbox(entry).padding(4) }
                    }
            }
        }
        .background(
            selection.contains(entry.id) ? Color.accentColor.opacity(0.18) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selection.contains(entry.id) ? Color.accentColor : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle()).help(entry.id)
        .accessibilityElement(children: showsCheckboxes ? .contain : .combine)
    }

    private func rowLabel(_ entry: BrowserEntry, size: CGFloat, showsPath: Bool) -> some View {
        HStack(spacing: 8) {
            if showsCheckboxes { checkbox(entry) }
            BrowserEntryLabel(entry: entry, size: size, showsPath: showsPath)
                .opacity(cutPaths.contains(entry.id) ? 0.5 : 1)
            if cutPaths.contains(entry.id) {
                Image(systemName: "scissors").font(.caption).foregroundStyle(.secondary).accessibilityLabel("待移动")
            }
        }
    }

    private func checkbox(_ entry: BrowserEntry) -> some View {
        Toggle(
            "选择 \(entry.name)",
            isOn: Binding(
                get: { selection.contains(entry.id) },
                set: { selected in
                    if selected { selection.insert(entry.id) } else { selection.remove(entry.id) }
                    anchor = entry.id
                    cursor = entry.id
                }
            )
        )
        .toggleStyle(.checkbox).labelsHidden()
        .help("选择或取消选择“\(entry.name)”")
        .padding(4)
        .background {
            BrowserMouseTarget(
                id: entry.id, usesTableRow: false, interaction: mouseInteraction,
                isSelectionControl: true)
        }
    }

    private func select(_ id: String, modifiers: NSEvent.ModifierFlags) {
        cursor = id
        if modifiers.contains(.shift), let anchor,
            let start = rows.firstIndex(where: { $0.id == anchor }),
            let end = rows.firstIndex(where: { $0.id == id })
        {
            selection = Set(rows[min(start, end)...max(start, end)].map(\.id))
        } else if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else {
            selection = [id]
            anchor = id
        }
    }
}

struct BrowserEntryIcon: View {
    let entry: BrowserEntry
    let size: CGFloat
    var body: some View {
        Image(systemName: symbol).resizable().scaledToFit()
            .foregroundStyle(entry.isDirectory ? Color.blue : entry.isArchive ? Color.orange : Color.secondary)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
    private var symbol: String {
        if entry.isDirectory { return "folder.fill" }
        if entry.isArchive { return "doc.zipper" }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return "photo"
        case "mp4", "mov", "mkv": return "film"
        case "mp3", "wav", "flac", "m4a": return "music.note"
        case "swift", "js", "ts", "cpp", "c", "py", "json": return "curlybraces"
        case "pdf", "txt", "md", "doc", "docx": return "doc.text"
        case "app": return "app.dashed"
        default: return "doc"
        }
    }
}

private struct BrowserEntryLabel: View {
    let entry: BrowserEntry
    let size: CGFloat
    let showsPath: Bool
    var body: some View {
        HStack(spacing: 8) {
            BrowserEntryIcon(entry: entry, size: size)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                if showsPath { Text(entry.id).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            if entry.isEncrypted {
                Image(systemName: "lock.fill").font(.caption).accessibilityLabel("已加密")
            }
            if entry.isLink { Image(systemName: "link").font(.caption).accessibilityLabel("链接") }
        }.help(entry.id)
    }
}

func copyBrowserPaths(_ paths: [String]) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
}

#Preview { BrowserViewMenu().padding() }
