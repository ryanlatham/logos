import Foundation

/// Outcome of decoding a list of wire dictionaries, tracking how many entries failed so the
/// caller can *surface* malformed frames instead of silently swallowing them — the core WS1 P3
/// goal ("surface decode failures instead of silent `compactMap` drops").
struct WireDecodeOutcome<Element> {
    let decoded: [Element]
    let droppedCount: Int

    var hasDrops: Bool { droppedCount > 0 }
}

enum LogosWireDecoder {
    /// Decode a heterogeneous list via `transform`, counting (rather than hiding) entries that
    /// fail to decode. Behaves like `rawItems.compactMap(transform)` for the success path while
    /// reporting how many were dropped.
    static func decodeList<Element>(
        _ rawItems: [[String: Any]],
        _ transform: ([String: Any]) -> Element?
    ) -> WireDecodeOutcome<Element> {
        var decoded: [Element] = []
        decoded.reserveCapacity(rawItems.count)
        var dropped = 0
        for raw in rawItems {
            if let value = transform(raw) {
                decoded.append(value)
            } else {
                dropped += 1
            }
        }
        return WireDecodeOutcome(decoded: decoded, droppedCount: dropped)
    }
}
