// G-38: the login item after the bundle identifier changed is registered again only when the earlier identity recorded
// it as on. Pure decisions and a throwaway TestDefaults domain; nothing here touches SMAppService.
import Foundation
import Testing
import ObscuraTestSupport
@testable import ObscuraCapture

@Suite struct LoginItemCarryOverTests {
    @Test func registersOnlyWhatThePersonHadOn() {
        #expect(LoginItemCarryOver.action(previouslyOn: true, status: .disabled) == .register)
        for status in [LoginItemStatus.enabled, .requiresApproval, .notFound] {
            #expect(LoginItemCarryOver.action(previouslyOn: true, status: status) == .leave, "\(status)")
        }
        for status in [LoginItemStatus.enabled, .disabled, .requiresApproval, .notFound] {
            #expect(LoginItemCarryOver.action(previouslyOn: false, status: status) == .leave, "off stays off: \(status)")
            #expect(LoginItemCarryOver.action(previouslyOn: nil, status: status) == .leave, "unknown is never turned on: \(status)")
        }
    }

    @Test func theMemoryFollowsWhatMacOSSays() {
        let d = TestDefaults("login").defaults
        #expect(LoginItem.lastKnownOn(in: d) == nil)
        LoginItem.remember(.enabled, in: d)
        #expect(LoginItem.lastKnownOn(in: d) == true)
        LoginItem.remember(.notFound, in: d)
        #expect(LoginItem.lastKnownOn(in: d) == true, "a copy outside Applications says nothing about the choice")
        LoginItem.remember(.disabled, in: d)
        #expect(LoginItem.lastKnownOn(in: d) == false)
        LoginItem.remember(.requiresApproval, in: d)
        #expect(LoginItem.lastKnownOn(in: d) == true)
    }
}
