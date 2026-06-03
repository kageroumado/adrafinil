import Foundation

/// Callback interface the **menu bar app** exports so the daemon can push state to it, turning the
/// app↔daemon channel from a poll into an event stream. The app sets an object conforming to this
/// as its connection's `exportedObject`; the daemon, after the app calls `DaemonXPCProtocol.subscribe`,
/// invokes `statusChanged` whenever the daemon's state actually changes (acquire/release, pause,
/// lid, cutout, away-summary). Replacing the old fixed-interval poll means neither process wakes the
/// CPU while nothing is happening — which is most of a sleep-management daemon's life.
///
/// `statusChanged` is reply-less (fire-and-forget): NSXPC delivers it on the receiver's private
/// queue, and a dropped push (dead connection) is harmless — the app re-subscribes on reconnect and
/// `subscribe` returns the current snapshot, so state is always eventually consistent.
@objc
public protocol AppXPCProtocol {
    /// A fresh `DaemonStatus` (JSON-encoded), pushed by the daemon on every state change.
    func statusChanged(_ encodedStatus: Data)
}
