import AppKit
import SwiftUI

struct ActivityView: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("操作记录").font(.largeTitle.weight(.bold))
                    Text("查看本次使用中的压缩、解压和测试结果。").foregroundStyle(.secondary)
                }
                Spacer()
                if !store.activity.isEmpty { Button("清除记录") { store.activity = [] }.disabled(store.isBusy) }
            }
            if store.activity.isEmpty {
                ContentUnavailableView(
                    "还没有操作记录", systemImage: "clock.arrow.circlepath",
                    description: Text("完成压缩、解压或测试后，结果会显示在这里。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.activity) { item in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: item.success ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.title2).foregroundStyle(item.success ? .green : .orange)
                            .accessibilityLabel(item.success ? "成功" : "未完成")
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.headline)
                            Text(item.detail).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(item.date, style: .time).font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if let output = item.output {
                            Button("显示结果") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                        }
                    }.padding(.vertical, 12)
                }.listStyle(.inset)
            }
        }.padding(32)
    }
}

#Preview { ActivityView(store: AppStore()) }
