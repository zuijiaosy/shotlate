import Foundation

/// Counts down whole seconds, then fires once. Used for "capture in N seconds" so menus and hover states can be set up first.
final class Countdown {
    private var timer: Timer?
    private(set) var remaining = 0

    var isRunning: Bool { timer != nil }

    /// `tick` gets the seconds left, starting with `seconds`; `fire` runs when it reaches zero.
    func start(seconds: Int, tick: @escaping (Int) -> Void, fire: @escaping () -> Void) {
        cancel()
        remaining = seconds
        tick(remaining)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.remaining -= 1
            if self.remaining <= 0 {
                self.cancel()
                fire()
            } else {
                tick(self.remaining)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        remaining = 0
    }
}
