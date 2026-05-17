import Foundation

/// Hybrid Logical Clock — gives a deterministic total order across devices
/// without a central server. `(wallMillis, counter, nodeID)` compares
/// lexicographically; the string form is sortable and filename-safe.
public struct HLC: Codable, Equatable, Comparable, Sendable, CustomStringConvertible {
    public var wallMillis: Int64
    public var counter: UInt32
    public var nodeID: String

    public init(wallMillis: Int64, counter: UInt32, nodeID: String) {
        self.wallMillis = wallMillis
        self.counter = counter
        self.nodeID = nodeID
    }

    public static func < (a: HLC, b: HLC) -> Bool {
        if a.wallMillis != b.wallMillis { return a.wallMillis < b.wallMillis }
        if a.counter != b.counter { return a.counter < b.counter }
        return a.nodeID < b.nodeID
    }

    /// Zero-padded, lexicographically sortable, safe as a path component.
    public var description: String {
        let w = String(format: "%015d", wallMillis)
        let c = String(format: "%010u", counter)
        return "\(w)-\(c)-\(nodeID)"
    }

    public static func parse(_ s: String) -> HLC? {
        let parts = s.split(separator: "-", maxSplits: 2).map(String.init)
        guard parts.count == 3,
              let w = Int64(parts[0]),
              let c = UInt32(parts[1]) else { return nil }
        return HLC(wallMillis: w, counter: c, nodeID: parts[2])
    }
}

/// Thread-safe HLC generator. `send()` on local events, `receive()` when
/// observing a remote event so local time never lags behind the network.
public final class HLCClock: @unchecked Sendable {
    private let nodeID: String
    private var last: HLC
    private let lock = NSLock()
    private let now: () -> Int64

    public init(nodeID: String, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.nodeID = nodeID
        self.now = now
        self.last = HLC(wallMillis: now(), counter: 0, nodeID: nodeID)
    }

    public func send() -> HLC {
        lock.lock(); defer { lock.unlock() }
        let physical = now()
        if physical > last.wallMillis {
            last = HLC(wallMillis: physical, counter: 0, nodeID: nodeID)
        } else {
            last = HLC(wallMillis: last.wallMillis, counter: last.counter &+ 1, nodeID: nodeID)
        }
        return last
    }

    public func receive(_ remote: HLC) {
        lock.lock(); defer { lock.unlock() }
        let physical = now()
        let maxWall = max(physical, max(last.wallMillis, remote.wallMillis))
        var c: UInt32
        if maxWall == last.wallMillis && maxWall == remote.wallMillis {
            c = max(last.counter, remote.counter) &+ 1
        } else if maxWall == last.wallMillis {
            c = last.counter &+ 1
        } else if maxWall == remote.wallMillis {
            c = remote.counter &+ 1
        } else {
            c = 0
        }
        last = HLC(wallMillis: maxWall, counter: c, nodeID: nodeID)
    }
}
