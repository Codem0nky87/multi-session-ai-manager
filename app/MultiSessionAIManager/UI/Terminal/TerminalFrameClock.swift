import Foundation
import QuartzCore

@MainActor
protocol TerminalFrameClock: AnyObject {
    var isRunning: Bool { get }
    func start(_ action: @escaping @MainActor () -> Void)
    func stop()
}

/// A demand-driven display clock. The run loop retains the display link, and the
/// display link retains its target, so the target must not retain this owner.
@MainActor
final class DisplayLinkTerminalFrameClock: TerminalFrameClock {
    private var displayLink: CADisplayLink?
    private var action: (@MainActor () -> Void)?
    private lazy var proxy = Proxy(owner: self)

    var isRunning: Bool { displayLink != nil }

    func start(_ action: @escaping @MainActor () -> Void) {
        guard displayLink == nil else { return }
        self.action = action

        let link = CADisplayLink(target: proxy, selector: #selector(Proxy.fire))
        proxy.link = link
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        action = nil
    }

    fileprivate func fire() {
        action?()
    }

    private final class Proxy: NSObject {
        weak var owner: DisplayLinkTerminalFrameClock?
        /// Weak because the run loop owns the scheduled link. If the clock is
        /// released without an explicit stop, the next fire retires that orphan.
        weak var link: CADisplayLink?

        init(owner: DisplayLinkTerminalFrameClock) {
            self.owner = owner
        }

        @MainActor @objc func fire() {
            guard let owner else {
                link?.invalidate()
                return
            }
            owner.fire()
        }
    }
}
