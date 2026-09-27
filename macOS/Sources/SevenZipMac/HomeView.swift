import SwiftUI

struct HomeView: View {
    @Bindable var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("文件打包，轻松一点。").font(.largeTitle.weight(.bold))
                    Text("熟悉的 7-Zip，为 Mac 带来更直观的归档体验。")
                        .font(.body).foregroundStyle(.secondary)
                }.padding(.top, 16)
                HStack(spacing: 16) {
                    ActionCard(
                        title: "打开压缩包", subtitle: "浏览内容，按需解压", symbol: "archivebox", shortcut: "⌘ O", prominent: true
                    ) {
                        store.chooseArchive()
                    }
                    ActionCard(
                        title: "新建压缩包", subtitle: "更小体积，安心分享", symbol: "plus.rectangle.on.folder", shortcut: "⌘ N",
                        prominent: false
                    ) {
                        store.beginCreate()
                    }
                }.disabled(store.isBusy)
                VStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.largeTitle).foregroundStyle(.blue).accessibilityHidden(true)
                    Text("把文件拖到这里").font(.title3.weight(.semibold))
                    Text("拖入压缩包以打开，或拖入文件和文件夹以创建归档。")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        ForEach(["7z", "ZIP", "RAR", "TAR", "可恢复 RZ"], id: \.self) { format in
                            Text(format).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.quaternary.opacity(0.5), in: Capsule())
                        }
                    }.padding(.top, 2)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 16)
                .background(Color.blue.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(
                        .blue.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("最近的归档").font(.headline)
                        Spacer()
                        if !store.recent.isEmpty {
                            Button("清除记录") { store.clearRecent() }.buttonStyle(.link).font(.caption)
                        }
                    }
                    if store.recent.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "clock").font(.title2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("从第一个归档开始").font(.subheadline.weight(.medium))
                                Text("打开或创建的压缩包会显示在这里。").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.padding(20).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        ForEach(store.recent.prefix(6)) { item in
                            Button {
                                store.openArchive(item.url)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.zipper").font(.title2).foregroundStyle(.blue)
                                        .frame(width: 36, height: 40)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.url.lastPathComponent).font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary).lineLimit(1)
                                        Text(item.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(
                                            .secondary
                                        ).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(item.date, style: .date).font(.caption).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }.padding(12).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(store.isBusy)
                            if item.id != store.recent.prefix(6).last?.id { Divider() }
                        }
                    }
                }
            }.padding(32).frame(maxWidth: 1050)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct ActionCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let shortcut: String
    let prominent: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: symbol).font(.title).accessibilityHidden(true)
                    Spacer()
                    Text(shortcut).font(.caption.monospaced()).opacity(0.75)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).font(.subheadline).opacity(prominent ? 0.9 : 0.7)
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(prominent ? .white : .primary)
                .background {
                    if prominent {
                        RoundedRectangle(cornerRadius: 16).fill(AppTheme.action.gradient)
                    } else {
                        RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(
                        prominent ? Color.clear : Color.primary.opacity(0.08))
                }
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}

#Preview { HomeView(store: AppStore()) }
