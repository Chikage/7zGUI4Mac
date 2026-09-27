import ArchiveCore
import Testing

@testable import SevenZipMac

@Test func operationIgnoresStaleAndCancelledProgress() {
    var operation = OperationState(title: "创建压缩包", detail: "准备中", showsCompression: true)
    let old = EngineProgress(fraction: 0.1, message: "旧数据")
    let newest = EngineProgress(fraction: 0.5, message: "正在压缩", compression: CompressionMetrics())
    operation.apply(newest)
    operation.apply(old)
    #expect(operation.fraction == 0.5)
    #expect(operation.detail == "正在压缩")
    operation.apply(EngineProgress(message: "正在校验"))
    #expect(operation.fraction == nil)
    #expect(operation.compression != nil)
    operation.cancelling = true
    operation.detail = "正在取消…"
    operation.apply(EngineProgress(fraction: 1, message: "已完成"))
    #expect(operation.detail == "正在取消…")
}
