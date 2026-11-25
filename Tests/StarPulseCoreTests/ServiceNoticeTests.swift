import Testing
@testable import StarPulseCore

@Suite struct ServiceNoticeTests {
    func status(disablement: Int = 1, down: Int = 1, up: Int = 1) -> DishStatus {
        var s = DishStatus()
        s.disablementCode = disablement; s.downloadLimitReason = down; s.uploadLimitReason = up
        return s
    }

    @Test func healthyServiceSaysNothing() {
        // Values read from a live dish with normal service: OKAY and NO_LIMIT.
        #expect(ServiceNotice.from(status()) == nil)
        #expect(ServiceNotice.from(DishStatus()) == nil) // fields absent on older firmware
    }

    @Test func disablementWinsAndIsCritical() {
        let notice = ServiceNotice.from(status(disablement: 7, down: 5, up: 5))
        #expect(notice?.critical == true)
        #expect(notice?.title == "Service restricted")
    }

    @Test func oneSidedLimitSaysWhichSide() {
        #expect(ServiceNotice.from(status(down: 6))?.text.hasSuffix("Download only.") == true)
        #expect(ServiceNotice.from(status(up: 3))?.text.hasSuffix("Upload only.") == true)
        #expect(ServiceNotice.from(status(down: 2, up: 2))?.critical == false)
    }

    @Test func unknownCodesStillShow() {
        #expect(ServiceNotice.from(status(disablement: 99))?.text.contains("code 99") == true)
        #expect(ServiceNotice.from(status(down: 42))?.text.contains("reason 42") == true)
    }
}
