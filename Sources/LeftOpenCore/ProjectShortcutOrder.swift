import Foundation

/// Stable shortcut order, independent of service discovery and changing ports.
public enum ProjectShortcutOrder {
    public static func normalized(current: [String], preferred: [String]) -> [String] {
        let available = Set(current)
        var seen = Set<String>()
        return (preferred + current).filter { available.contains($0) && seen.insert($0).inserted }
    }

    public static func moving(_ id: String, to target: String, in order: [String]) -> [String] {
        guard id != target, let from = order.firstIndex(of: id), let to = order.firstIndex(of: target) else { return order }
        var result = order
        result.remove(at: from)
        result.insert(id, at: to)
        return result
    }
}
