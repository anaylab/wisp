import Testing
@testable import Wisp

@MainActor
struct WindowPositionManagerPermissionTests {

    @Test func firstRequestShowsTheSystemDialog() {
        let destination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(destination == .systemPrompt)
    }

    @Test func secondRequestSendsTheUserToSystemSettings() {
        let destination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(destination == .systemSettings)
    }

    @Test func rememberedScreenRecordingGrantSkipsTheGate() {
        let isTreatedAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(isTreatedAsGranted)
    }
}
