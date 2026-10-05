// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// One heartbeat for every feature that watches the general pasteboard.
/// Clipboard history, the URL cleaner and auto-clear used to run a timer
/// each, and each tick crossed to the pasteboard lane only to read the
/// change count. Here a single timer reads it once and hands the same value
/// to every subscriber on the main thread; a subscriber only goes back to
/// the lane for content when the count actually moved.
///
/// The timer runs only while someone subscribes, and at most one read is
/// ever in flight: behind an app that promised pasteboard content and
/// stopped answering, ticks are skipped instead of queueing (issue #887).
final class PasteboardChangeMonitor {
    static let shared = PasteboardChangeMonitor()

    static let interval: TimeInterval = 0.8

    /// Reads the change count and answers on the main thread.
    typealias Reader = (_ completion: @escaping (Int) -> Void) -> Void
    /// Starts a repeating timer and returns what stops it.
    typealias TimerFactory = (_ interval: TimeInterval,
                              _ tick: @escaping () -> Void) -> (() -> Void)

    final class Subscription {
        fileprivate let handler: (Int) -> Void
        fileprivate init(_ handler: @escaping (Int) -> Void) { self.handler = handler }
    }

    private let read: Reader
    private let makeTimer: TimerFactory
    private var subscriptions: [Subscription] = []
    private var stopTimer: (() -> Void)?
    private var readInFlight = false
    private var readGeneration = 0

    init(read: Reader? = nil, makeTimer: TimerFactory? = nil) {
        self.read = read ?? { completion in
            GeneralPasteboardAccess.shared.async({ NSPasteboard.general.changeCount }, then: completion)
        }
        self.makeTimer = makeTimer ?? { interval, tick in
            let timer = Timer(timeInterval: interval, repeats: true) { _ in tick() }
            timer.tolerance = 0.25
            // The common modes keep it beating while a menu or slider tracks
            // the mouse, as each service's own timer did.
            RunLoop.main.add(timer, forMode: .common)
            return { timer.invalidate() }
        }
    }

    var isRunning: Bool { stopTimer != nil }

    /// `handler` receives the change count on the main thread after every
    /// read, changed or not, until the subscription is cancelled.
    func subscribe(_ handler: @escaping (Int) -> Void) -> Subscription {
        precondition(Thread.isMainThread)
        let subscription = Subscription(handler)
        subscriptions.append(subscription)
        if stopTimer == nil {
            stopTimer = makeTimer(Self.interval) { [weak self] in self?.tick() }
        }
        return subscription
    }

    func cancel(_ subscription: Subscription) {
        precondition(Thread.isMainThread)
        subscriptions.removeAll { $0 === subscription }
        guard subscriptions.isEmpty, let stopTimer else { return }
        stopTimer()
        self.stopTimer = nil
        // A read still wedged on the lane answers no one; the next run starts
        // its own instead of waiting for it.
        readGeneration &+= 1
        readInFlight = false
    }

    func tick() {
        precondition(Thread.isMainThread)
        guard !readInFlight, !subscriptions.isEmpty else { return }
        readInFlight = true
        readGeneration &+= 1
        let generation = readGeneration
        read { [weak self] changeCount in
            guard let self, self.readGeneration == generation else { return }
            self.readInFlight = false
            // A handler may cancel itself or another subscription: walk a
            // snapshot and skip any that an earlier handler just cancelled.
            for subscription in self.subscriptions where self.subscriptions.contains(where: { $0 === subscription }) {
                subscription.handler(changeCount)
            }
        }
    }
}
