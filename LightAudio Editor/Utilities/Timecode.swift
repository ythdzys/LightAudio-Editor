import Foundation

enum Timecode {
    static func string(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let hours = Int(clamped / 3600)
        let minutes = Int(clamped / 60) % 60
        let secs = Int(clamped.truncatingRemainder(dividingBy: 60))
        let millis = Int((clamped - floor(clamped)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }

    static func seconds(_ string: String) -> TimeInterval? {
        let parts = string.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secondsPart = parts.last ?? ""
        let secondPieces = secondsPart.split(separator: ".", omittingEmptySubsequences: false)
        guard let secs = Double(secondPieces.first ?? "") else { return nil }
        let millis = secondPieces.count > 1 ? Double("0.\(secondPieces[1])") ?? 0 : 0
        if parts.count == 3 {
            guard let hours = Double(parts[0]), let minutes = Double(parts[1]) else { return nil }
            return max(0, hours * 3600 + minutes * 60 + secs + millis)
        }
        guard let minutes = Double(parts[0]) else { return nil }
        return max(0, minutes * 60 + secs + millis)
    }
}
