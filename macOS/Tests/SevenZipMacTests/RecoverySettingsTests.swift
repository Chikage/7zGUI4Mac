import ArchiveCore
import Testing

@testable import SevenZipMac

@Test func recoveryDraftValidatesBothCountsBeforeSubmitting() throws {
    var draft = RecoverySettingsDraft()
    #expect(try draft.counts() == RecoveryVolumeCounts(data: 10, recovery: 2))
    #expect(draft.isValid)
    draft.dataVolumes = "1"
    #expect(!draft.isValid && draft.recoveryError != nil)
    draft.recoveryVolumes = "1"
    #expect(draft.isValid)
    draft.dataVolumes = "2.5"
    #expect(!draft.isValid && draft.dataError != nil)
    draft.dataVolumes = "100"
    draft.recoveryVolumes = "100"
    #expect(draft.isValid)
    draft.recoveryVolumes = "0"
    #expect(!draft.isValid && draft.recoveryError != nil)
}
