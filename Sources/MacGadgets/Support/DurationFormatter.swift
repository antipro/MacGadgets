import Foundation

/// Formats a remaining-time value the way a menu bar countdown should read:
/// `1:23:45` for hours, `23:45` for under an hour.
enum DurationFormatter {
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// `1 小时 30 分`, `16 小时`, `45 秒` — used for menu labels.
    static func humanReadable(_ seconds: TimeInterval) -> String {
        let total = max(1, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) 小时") }
        if minutes > 0 { parts.append("\(minutes) 分") }
        if hours == 0 && secs > 0 { parts.append("\(secs) 秒") }
        return parts.isEmpty ? "0 秒" : parts.joined()
    }

    /// Parses `"90"`, `"90m"`, `"2h"`, `"1h30m"`, `"57600s"`, `"16:00:00"`, `"16 小时"`. Returns seconds.
    static func parse(_ raw: String) -> TimeInterval? {
        let text = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty else { return nil }

        // Colon format: HH:MM:SS or MM:SS
        if text.contains(":") {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 || parts.count == 3,
                  parts.allSatisfy({ !$0.isEmpty }),
                  let values = Optional(parts.compactMap { Double($0) }),
                  values.count == parts.count,
                  values.allSatisfy({ $0 >= 0 }) else {
                return nil
            }
            let total: Double
            if values.count == 3 {
                total = values[0] * 3600 + values[1] * 60 + values[2]
            } else {
                total = values[0] * 60 + values[1]
            }
            return total > 0 ? total : nil
        }

        // Plain number means minutes, matching how people think about a duration.
        if let minutes = Double(text) {
            return minutes > 0 ? minutes * 60 : nil
        }

        var total: Double = 0
        var scannedSomething = false
        var index = text.startIndex

        while index < text.endIndex {
            var number = ""
            while index < text.endIndex, text[index].isNumber || text[index] == "." {
                number.append(text[index])
                index = text.index(after: index)
            }
            guard let value = Double(number) else { return nil }

            var unit = ""
            while index < text.endIndex, text[index].isLetter {
                unit.append(text[index])
                index = text.index(after: index)
            }

            let multiplier: Double
            switch unit {
            case "h", "时", "小时":
                multiplier = 3600
            case "m", "分", "分钟":
                multiplier = 60
            case "s", "秒":
                multiplier = 1
            case "":
                // A bare second number in a compound expression, e.g. "1h30".
                multiplier = 60
            default:
                return nil
            }
            total += value * multiplier
            scannedSomething = true
        }

        guard scannedSomething, total > 0 else { return nil }
        return total
    }
}
