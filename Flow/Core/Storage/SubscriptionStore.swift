import Foundation

/// A channel the viewer follows, stored locally. Flow has no account, so a subscription is a row in
/// this table rather than a server-side relation.
struct Subscription {
    let channelId: String
    let name: String
    let avatarUrl: String
    let subscriberCount: Int
    let subscribedAt: Date
    let notificationsEnabled: Bool
}

/// The locally persisted subscription list. Lookups are served from an in-memory index so a feed
/// with hundreds of rows does not hit SQLite for every cell.
final class SubscriptionStore {

    static let shared = SubscriptionStore()

    private let database: FlowDB
    private let queue = DispatchQueue(label: "org.flowtube.Flow.subscriptions", qos: .utility)
    private let lock = NSLock()
    private var index: [String: Subscription] = [:]
    private var ordered: [Subscription] = []

    init(database: FlowDB = FlowDB.shared) {
        self.database = database
        reloadIndex()
    }

    // MARK: - Reading

    /// Every subscription, newest first.
    var all: [Subscription] {
        lock.lock()
        defer { lock.unlock() }
        return ordered
    }

    /// Subscriptions sorted by name, for the alphabetical list.
    var alphabetically: [Subscription] {
        return all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The number of subscribed channels.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return ordered.count
    }

    /// Whether `channelId` is followed.
    func isSubscribed(_ channelId: String) -> Bool {
        guard !channelId.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return index[channelId] != nil
    }

    /// The stored row for a channel, if any.
    func subscription(for channelId: String) -> Subscription? {
        lock.lock()
        defer { lock.unlock() }
        return index[channelId]
    }

    /// Channels whose name matches `query`.
    func search(_ query: String) -> [Subscription] {
        let trimmed = query.trimmed
        guard !trimmed.isEmpty else { return alphabetically }
        return alphabetically.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    /// The ids of every subscribed channel, for the feed request.
    var channelIds: [String] {
        return all.map { $0.channelId }
    }

    // MARK: - Writing

    /// Follows a channel. Re-subscribing refreshes the stored metadata without changing the date.
    func subscribe(channelId: String, name: String, avatarUrl: String, subscriberCount: Int) {
        guard !channelId.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let existing = self.subscription(for: channelId)
            let subscribedAt = existing?.subscribedAt ?? Date()
            let notifications = existing?.notificationsEnabled ?? true
            self.database.execute(
                """
                INSERT INTO subscriptions (channel_id, name, avatar_url, subscriber_count, subscribed_at, notifications_enabled)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(channel_id) DO UPDATE SET
                    name = excluded.name,
                    avatar_url = excluded.avatar_url,
                    subscriber_count = excluded.subscriber_count;
                """,
                [
                    .text(channelId),
                    .text(name),
                    .text(avatarUrl),
                    .int(subscriberCount),
                    .date(subscribedAt),
                    .bool(notifications),
                ]
            )
            self.reloadIndex()
            FlowEventBus.shared.broadcast("subscriptions", notification: .flowSubscriptionsDidChange, payload: channelId)
        }
    }

    /// Unfollows a channel.
    func unsubscribe(channelId: String) {
        guard !channelId.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute("DELETE FROM subscriptions WHERE channel_id = ?;", [.text(channelId)])
            self.reloadIndex()
            FlowEventBus.shared.broadcast("subscriptions", notification: .flowSubscriptionsDidChange, payload: channelId)
        }
    }

    /// Follows or unfollows, whichever the current state is not. Returns the new state.
    @discardableResult
    func toggle(channelId: String, name: String, avatarUrl: String, subscriberCount: Int) -> Bool {
        if isSubscribed(channelId) {
            unsubscribe(channelId: channelId)
            return false
        }
        subscribe(channelId: channelId, name: name, avatarUrl: avatarUrl, subscriberCount: subscriberCount)
        return true
    }

    /// Turns upload notifications for one channel on or off.
    func setNotifications(enabled: Bool, channelId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute(
                "UPDATE subscriptions SET notifications_enabled = ? WHERE channel_id = ?;",
                [.bool(enabled), .text(channelId)]
            )
            self.reloadIndex()
        }
    }

    /// Replaces the whole list, as the import reader does.
    func replaceAll(_ subscriptions: [Subscription]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.transaction { transaction in
                transaction.execute("DELETE FROM subscriptions;")
                for item in subscriptions {
                    transaction.execute(
                        """
                        INSERT OR REPLACE INTO subscriptions
                        (channel_id, name, avatar_url, subscriber_count, subscribed_at, notifications_enabled)
                        VALUES (?, ?, ?, ?, ?, ?);
                        """,
                        [
                            .text(item.channelId),
                            .text(item.name),
                            .text(item.avatarUrl),
                            .int(item.subscriberCount),
                            .date(item.subscribedAt),
                            .bool(item.notificationsEnabled),
                        ]
                    )
                }
            }
            self.reloadIndex()
            FlowEventBus.shared.broadcast("subscriptions", notification: .flowSubscriptionsDidChange)
        }
    }

    /// Removes every subscription.
    func clear() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.execute("DELETE FROM subscriptions;")
            self.reloadIndex()
            FlowEventBus.shared.broadcast("subscriptions", notification: .flowSubscriptionsDidChange)
        }
    }

    // MARK: - Index

    private func reloadIndex() {
        let rows = database.query("SELECT * FROM subscriptions ORDER BY subscribed_at DESC;")
        let items = rows.map { row in
            Subscription(
                channelId: row.string("channel_id"),
                name: row.string("name"),
                avatarUrl: row.string("avatar_url"),
                subscriberCount: row.int("subscriber_count"),
                subscribedAt: row.date("subscribed_at") ?? Date(timeIntervalSince1970: 0),
                notificationsEnabled: row.bool("notifications_enabled")
            )
        }
        var newIndex: [String: Subscription] = [:]
        for item in items {
            newIndex[item.channelId] = item
        }
        lock.lock()
        index = newIndex
        ordered = items
        lock.unlock()
    }
}
