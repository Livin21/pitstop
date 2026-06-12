import Foundation

enum Format {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM, h:mm a"
        return f
    }()

    static func percent(_ v: Double?) -> String {
        guard let v else { return "–" }
        return "\(Int(v.rounded()))%"
    }

    static func reset(_ date: Date?) -> String {
        guard let date else { return "" }
        let stamp = Calendar.current.isDateInToday(date)
            ? time.string(from: date)
            : day.string(from: date)
        return "resets \(stamp) (\(relative(date.timeIntervalSinceNow)))"
    }

    static func relative(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let d = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        if d > 0 { return "in \(d)d \(h)h" }
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(m)m"
    }

    static let updated: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }()

    private static let weekdayTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return f
    }()

    /// Short reset stamp for the menu rows: "9:49 PM · 3h 34m" /
    /// "Thu 10:29 AM · 5d 16h".
    static func compactReset(_ date: Date?) -> String {
        guard let date else { return "" }
        let stamp = Calendar.current.isDateInToday(date)
            ? time.string(from: date)
            : weekdayTime.string(from: date)
        return "\(stamp) · \(relativeShort(date.timeIntervalSinceNow))"
    }

    static func relativeShort(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let d = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
