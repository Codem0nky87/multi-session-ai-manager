import Testing
import CoreGraphics
import UIKit
@testable import MultiSessionAIManager

@Suite struct KeyboardVisibilityTests {
    @Test func dockedKeyboardReportsItsOverlap() {
        #expect(KeyboardVisibilityModel.dockedOverlap(
            in: CGRect(x: 0, y: 0, width: 1024, height: 768),
            keyboardEnd: CGRect(x: 0, y: 503, width: 1024, height: 265)) == 265)
    }

    @Test func floatingKeyboardCostsNothing() {
        #expect(KeyboardVisibilityModel.dockedOverlap(
            in: CGRect(x: 0, y: 0, width: 1024, height: 768),
            keyboardEnd: CGRect(x: 300, y: 400, width: 424, height: 300)) == 0)
    }

    @Test func floatingKeyboardAtBottomDoesNotShrinkTheWholeTerminal() {
        #expect(KeyboardVisibilityModel.dockedOverlap(
            in: CGRect(x: 0, y: 0, width: 1024, height: 768),
            keyboardEnd: CGRect(x: 300, y: 468, width: 424, height: 300)) == 0)
    }

    @Test func overlapCannotExceedTheWindow() {
        #expect(KeyboardVisibilityModel.dockedOverlap(
            in: CGRect(x: 0, y: 0, width: 1024, height: 768),
            keyboardEnd: CGRect(x: 0, y: -256, width: 1024, height: 1024)) == 768)
    }

    @Test func tallIPadKeyboardKeepsItsActualOverlap() {
        // Smaller iPad windows can legitimately give more than 45% to the keyboard.
        #expect(KeyboardVisibilityModel.dockedOverlap(
            in: CGRect(x: 0, y: 0, width: 800, height: 600),
            keyboardEnd: CGRect(x: 0, y: 300, width: 800, height: 300)) == 300)
    }

    @Test func iPhoneLandscapeKeyboardKeepsItsActualOverlap() {
        #expect(KeyboardVisibilityModel.dockedOverlap(
            in: CGRect(x: 0, y: 0, width: 956, height: 440),
            keyboardEnd: CGRect(x: 0, y: 207, width: 956, height: 233)) == 233)
    }

    @Test func convertedFrameOnlyReservesThePartInsideTheWindow() {
        // Screen keyboard y=900...1200, window y=500...1100. After conversion
        // its y is 400...700, of which only 200 points overlap this 600pt window.
        #expect(KeyboardVisibilityModel.dockedOverlap(
            in: CGRect(x: 0, y: 0, width: 800, height: 600),
            keyboardEnd: CGRect(x: -100, y: 400, width: 1200, height: 300)) == 200)
    }

    @Test func keyboardOutsideWindowCostsNothing() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        for frame in [CGRect.zero,
                      CGRect(x: 0, y: 600, width: 600, height: 300),
                      CGRect(x: 700, y: 300, width: 600, height: 300)] {
            #expect(KeyboardVisibilityModel.dockedOverlap(in: bounds, keyboardEnd: frame) == 0)
        }
    }

    @Test @MainActor func floatingKeyboardRemainsVisibleUntilDismissed() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = try #require(scene.windows.first { $0.isKeyWindow })
        let model = KeyboardVisibilityModel()
        let center = NotificationCenter.default
        defer { center.post(name: UIResponder.keyboardDidHideNotification, object: window.screen) }
        let floating = CGRect(x: 20, y: 100, width: 200, height: 200)
        center.post(name: UIResponder.keyboardDidChangeFrameNotification, object: window.screen,
                    userInfo: [UIResponder.keyboardFrameEndUserInfoKey:
                        window.convert(floating, to: window.screen.coordinateSpace)])
        #expect(model.height == 0)
        #expect(model.isVisible, "The quick-key toggle must still be able to dismiss a floating keyboard")
        center.post(name: UIResponder.keyboardDidChangeFrameNotification, object: window.screen,
                    userInfo: [UIResponder.keyboardFrameEndUserInfoKey:
                        window.convert(CGRect(x: 0, y: window.bounds.maxY, width: window.bounds.width, height: 300),
                                       to: window.screen.coordinateSpace)])
        #expect(!model.isVisible, "An offscreen frame change must clear visibility even without didHide")
        center.post(name: UIResponder.keyboardDidShowNotification, object: window.screen,
                    userInfo: [UIResponder.keyboardFrameEndUserInfoKey:
                        window.convert(floating, to: window.screen.coordinateSpace)])
        #expect(model.isVisible)
        center.post(name: UIResponder.keyboardDidHideNotification, object: window.screen)
        #expect(!model.isVisible)
        #expect(model.height == 0)
    }
}
