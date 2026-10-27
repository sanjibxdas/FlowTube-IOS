import Foundation

/// A token returned by `FlowObservable.observe`. Hold it for as long as you want the callback;
/// deallocating it removes the observer. This is the app's stand-in for Combine, which is iOS 13+.
final class ObservationToken {
    private var cancel: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    func cancelObservation() {
        let action = cancel
        cancel = nil
        action?()
    }

    deinit {
        cancel?()
    }
}

/// A tiny thread-safe observable value. Every mutation is delivered on the main queue, in order,
/// so UI code can subscribe without hopping queues itself.
final class FlowObservable<Value> {

    private let lock = NSLock()
    private var valueStorage: Value
    private var observers: [UUID: (Value) -> Void] = [:]

    init(_ value: Value) {
        valueStorage = value
    }

    /// The current value. Safe to read from any thread.
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return valueStorage
    }

    /// Sets the value and notifies every observer on the main queue.
    func set(_ newValue: Value) {
        lock.lock()
        valueStorage = newValue
        let snapshot = Array(observers.values)
        lock.unlock()
        deliver(newValue, to: snapshot)
    }

    /// Sets the value without notifying observers. Used while restoring persisted state.
    func setSilently(_ newValue: Value) {
        lock.lock()
        valueStorage = newValue
        lock.unlock()
    }

    /// Applies a mutation to the value and notifies observers.
    func mutate(_ transform: (inout Value) -> Void) {
        lock.lock()
        var copy = valueStorage
        transform(&copy)
        valueStorage = copy
        let snapshot = Array(observers.values)
        lock.unlock()
        deliver(copy, to: snapshot)
    }

    /// Registers `handler` and calls it immediately with the current value. Keep the returned token.
    @discardableResult
    func observe(_ handler: @escaping (Value) -> Void) -> ObservationToken {
        let identifier = UUID()
        lock.lock()
        observers[identifier] = handler
        let current = valueStorage
        lock.unlock()
        if Thread.isMainThread {
            handler(current)
        } else {
            DispatchQueue.main.async {
                handler(current)
            }
        }
        return ObservationToken { [weak self] in
            self?.removeObserver(identifier)
        }
    }

    /// Registers `handler` without the immediate call, for screens that already rendered the value.
    @discardableResult
    func observeChanges(_ handler: @escaping (Value) -> Void) -> ObservationToken {
        let identifier = UUID()
        lock.lock()
        observers[identifier] = handler
        lock.unlock()
        return ObservationToken { [weak self] in
            self?.removeObserver(identifier)
        }
    }

    private func removeObserver(_ identifier: UUID) {
        lock.lock()
        observers.removeValue(forKey: identifier)
        lock.unlock()
    }

    private func deliver(_ newValue: Value, to handlers: [(Value) -> Void]) {
        guard !handlers.isEmpty else { return }
        let work = {
            for handler in handlers {
                handler(newValue)
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

/// A one-shot, multi-listener event bus for app-wide signals (theme changed, history changed).
/// Listeners are keyed by object identity so a screen can remove all of its own registrations.
final class FlowEventBus {

    static let shared = FlowEventBus()

    private let lock = NSLock()
    private var listeners: [String: [UUID: (Any?) -> Void]] = [:]

    private init() {}

    /// Subscribes to `name`. The returned token unsubscribes when released.
    @discardableResult
    func on(_ name: String, handler: @escaping (Any?) -> Void) -> ObservationToken {
        let identifier = UUID()
        lock.lock()
        var bucket = listeners[name] ?? [:]
        bucket[identifier] = handler
        listeners[name] = bucket
        lock.unlock()
        return ObservationToken { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.listeners[name]?.removeValue(forKey: identifier)
            self.lock.unlock()
        }
    }

    /// Posts an event to every listener on the main queue.
    func post(_ name: String, payload: Any? = nil) {
        lock.lock()
        let snapshot = Array((listeners[name] ?? [:]).values)
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        let work = {
            for handler in snapshot {
                handler(payload)
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// Posts a `Notification` as well, so UIKit-style observers see the same signal.
    func broadcast(_ name: String, notification: Notification.Name, payload: Any? = nil) {
        post(name, payload: payload)
        NotificationCenter.default.post(name: notification, object: payload)
    }
}

/// A cancellable bundle of observation tokens. A view controller keeps one and cancels it in
/// `deinit`, which is the closest iOS 12 gets to automatic subscription lifetimes.
final class ObservationBag {

    private var tokens: [ObservationToken] = []
    private let lock = NSLock()

    init() {}

    func add(_ token: ObservationToken) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let snapshot = tokens
        tokens.removeAll()
        lock.unlock()
        for token in snapshot {
            token.cancelObservation()
        }
    }

    deinit {
        cancelAll()
    }
}

/// A debouncer for search-as-you-type and similar bursts. Runs on the main queue.
final class FlowDebouncer {

    private let interval: TimeInterval
    private var pending: DispatchWorkItem?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Schedules `action`, cancelling any previously scheduled call.
    func schedule(_ action: @escaping () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem(block: action)
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
    }

    /// Drops the pending call, if there is one.
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    deinit {
        pending?.cancel()
    }
}

/// Coalesces many calls into one run on the next main-loop turn. Used to batch table reloads.
final class FlowCoalescer {

    private var scheduled = false
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func trigger() {
        if scheduled { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.scheduled = false
            self.action()
        }
    }
}
