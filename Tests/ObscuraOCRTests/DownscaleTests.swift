import CoreGraphics
import Testing
@testable import ObscuraOCR

@Suite struct DownscaleTests {
    @Test func underBudgetIsIdentity() {
        let plan = DownscalePlan(width: 4000, height: 6000, options: OCROptions())   // exactly 24 MP, not over
        #expect(plan.isIdentity)
        #expect(plan.scaledBack(CGRect(x: 1, y: 2, width: 3, height: 4)) == CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    @Test func overBudgetShrinksLongestSide() {
        let plan = DownscalePlan(width: 8192, height: 4096, options: OCROptions())
        #expect(plan.workSize == CGSize(width: 4096, height: 2048))
        #expect(plan.scaleX == 2 && plan.scaleY == 2)
        let back = plan.scaledBack(CGRect(x: 10, y: 20, width: 30, height: 40))
        #expect(back == CGRect(x: 20, y: 40, width: 60, height: 80))
    }

    @Test func nonIntegerRatioScalesBackExactly() {
        let plan = DownscalePlan(width: 7000, height: 5000, options: OCROptions())
        #expect(plan.workSize.width == 4096)
        #expect(Int(plan.workSize.height) == 2926)   // 5000 × 4096 / 7000 = 2925.71, rounded
        let full = plan.scaledBack(CGRect(x: 0, y: 0, width: plan.workSize.width, height: plan.workSize.height))
        #expect(abs(full.width - 7000) < 1e-9 && abs(full.height - 5000) < 1e-9)
    }

    @Test func renderProducesPlannedSize() throws {
        let plan = DownscalePlan(width: 64, height: 32, options: OCROptions(pixelBudget: 1000, maxLongestSide: 16))
        let small = try Downscaler.render(blankImage(width: 64, height: 32), to: plan)
        #expect(small.width == 16 && small.height == 8)
    }

    @Test func pathologicalOptionsStillMeetBudget() {
        let plan = DownscalePlan(width: 1000, height: 1000, options: OCROptions(pixelBudget: 10_000, maxLongestSide: 4096))
        #expect(plan.workSize.width * plan.workSize.height <= 10_000)
    }
}
