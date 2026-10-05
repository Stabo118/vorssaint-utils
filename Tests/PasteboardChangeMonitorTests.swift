// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct PasteboardChangeMonitorTests {
    static func run(_ suite: TestSuite) {
        precondition(Thread.isMainThread)

        var pendingReads: [(Int) -> Void] = []
        var timersStarted = 0
        var timersStopped = 0
        let monitor = PasteboardChangeMonitor(
            read: { pendingReads.append($0) },
            makeTimer: { _, _ in
                timersStarted += 1
                return { timersStopped += 1 }
            })

        monitor.tick()
        suite.expect(pendingReads.isEmpty, "nothing is read while no one watches the pasteboard")
        suite.expect(!monitor.isRunning, "no timer runs without a subscriber")

        var history: [Int] = []
        var cleaner: [Int] = []
        let historySubscription = monitor.subscribe { history.append($0) }
        let cleanerSubscription = monitor.subscribe { cleaner.append($0) }
        suite.expect(timersStarted == 1, "every watcher shares one timer")

        monitor.tick()
        monitor.tick()
        suite.expect(pendingReads.count == 1, "one read serves every watcher, and a pending read is not stacked")
        pendingReads.removeFirst()(7)
        suite.expect(history == [7] && cleaner == [7], "every watcher receives the same change count")

        monitor.tick()
        pendingReads.removeFirst()(7)
        suite.expect(history == [7, 7] && cleaner == [7, 7],
                     "an unchanged count still reaches watchers that keep time, such as auto-clear")

        // A watcher that stops another one during delivery stops it at once.
        monitor.cancel(historySubscription)
        var skipped: [Int] = []
        var skippedSubscription: PasteboardChangeMonitor.Subscription?
        var stopping: PasteboardChangeMonitor.Subscription?
        stopping = monitor.subscribe { _ in
            if let skippedSubscription { monitor.cancel(skippedSubscription) }
            if let stopping { monitor.cancel(stopping) }
        }
        monitor.cancel(cleanerSubscription)
        skippedSubscription = monitor.subscribe { skipped.append($0) }
        monitor.tick()
        pendingReads.removeFirst()(8)
        suite.expect(history == [7, 7] && cleaner == [7, 7], "a cancelled watcher receives nothing more")
        suite.expect(skipped.isEmpty, "a watcher cancelled earlier in the same delivery is skipped")
        suite.expect(!monitor.isRunning && timersStopped == 1, "the timer stops with the last watcher")

        // A read wedged behind an unresponsive app answers no later run.
        let late = monitor.subscribe { history.append($0) }
        monitor.tick()
        let wedged = pendingReads.removeFirst()
        monitor.cancel(late)
        let fresh = monitor.subscribe { history.append($0) }
        monitor.tick()
        suite.expect(pendingReads.count == 1, "a new run reads again instead of waiting for a wedged read")
        wedged(9)
        suite.expect(history == [7, 7], "the wedged read's answer is dropped")
        pendingReads.removeFirst()(10)
        suite.expect(history == [7, 7, 10], "the new run's read is delivered")
        monitor.cancel(fresh)
        suite.expect(timersStarted == 3 && timersStopped == 3, "each run starts and stops its timer once")
    }
}
