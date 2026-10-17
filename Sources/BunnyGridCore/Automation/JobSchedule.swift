import Foundation

/// When a batch job runs by itself (Navicat's "Set Task Schedule").
/// Weekdays use `Calendar` numbering: 1 = Sunday … 7 = Saturday.
public enum JobSchedule: Codable, Hashable, Sendable {
    /// Only when run by hand.
    case manual
    case once(Date)
    case hourly(minute: Int)
    case daily(hour: Int, minute: Int)
    case weekly(weekdays: [Int], hour: Int, minute: Int)
    case monthly(day: Int, hour: Int, minute: Int)
    /// A five-field cron expression: minute hour day-of-month month day-of-week.
    case cron(String)

    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case manual, once, hourly, daily, weekly, monthly, cron
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .manual: "Manual only"
            case .once: "Once"
            case .hourly: "Hourly"
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            case .cron: "Custom (cron)"
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .manual: .manual
        case .once: .once
        case .hourly: .hourly
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .cron: .cron
        }
    }

    public var isScheduled: Bool { self != .manual }

    /// The equivalent cron expression of the repeating schedules (nil for manual and once).
    public func cronExpression() throws -> CronExpression? {
        switch self {
        case .manual, .once: return nil
        case .hourly(let minute): return try CronExpression("\(minute) * * * *")
        case .daily(let hour, let minute): return try CronExpression("\(minute) \(hour) * * *")
        case .weekly(let weekdays, let hour, let minute):
            let days = weekdays.isEmpty ? "*" : Set(weekdays).sorted().map { String(($0 - 1) % 7) }.joined(separator: ",")
            return try CronExpression("\(minute) \(hour) * * \(days)")
        case .monthly(let day, let hour, let minute): return try CronExpression("\(minute) \(hour) \(day) * *")
        case .cron(let text): return try CronExpression(text)
        }
    }

    /// The first run strictly after `date`, or nil when there is none (manual, a past "once", an invalid expression).
    public func nextRun(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .manual: return nil
        case .once(let when): return when > date ? when : nil
        default: return (try? cronExpression())??.next(after: date, calendar: calendar)
        }
    }

    public func nextRuns(after date: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        var result: [Date] = []
        var cursor = date
        while result.count < count, let next = nextRun(after: cursor, calendar: calendar) {
            result.append(next)
            cursor = next
        }
        return result
    }

    /// launchd's `StartCalendarInterval` entries (keys Minute, Hour, Day, Weekday 0 = Sunday, Month).
    /// A once schedule fires on its month, day and time every year; the runner skips the later years.
    public func launchdCalendarIntervals(calendar: Calendar = .current) throws -> [[String: Int]] {
        switch self {
        case .manual: return []
        case .once(let date):
            let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
            return [["Month": c.month ?? 1, "Day": c.day ?? 1, "Hour": c.hour ?? 0, "Minute": c.minute ?? 0]]
        default:
            guard let cron = try cronExpression() else { return [] }
            return try cron.launchdCalendarIntervals()
        }
    }

    /// "Every day at 03:00", "Mon, Wed at 08:30", …
    public func summary(calendar: Calendar = .current) -> String {
        func time(_ h: Int, _ m: Int) -> String { String(format: "%02d:%02d", h, m) }
        switch self {
        case .manual: return "Manual only"
        case .once(let date): return "Once on " + date.formatted(date: .abbreviated, time: .shortened)
        case .hourly(let minute): return "Every hour at :\(String(format: "%02d", minute))"
        case .daily(let h, let m): return "Every day at \(time(h, m))"
        case .weekly(let days, let h, let m):
            let symbols = calendar.shortWeekdaySymbols
            let names = Set(days).sorted().compactMap { (1...7).contains($0) ? symbols[$0 - 1] : nil }
            return "\(names.isEmpty ? "Every day" : names.joined(separator: ", ")) at \(time(h, m))"
        case .monthly(let d, let h, let m): return "Day \(d) of every month at \(time(h, m))"
        case .cron(let text): return "cron: \(text)"
        }
    }
}

/// A five-field cron expression (`minute hour day-of-month month day-of-week`) with `*`, lists, ranges and steps.
/// As in cron, when both day fields are restricted a day matching either one runs.
public struct CronExpression: Hashable, Sendable {
    public enum ParseError: LocalizedError, Equatable {
        case fieldCount(Int)
        case invalidField(String)
        case tooManyIntervals(Int)

        public var errorDescription: String? {
            switch self {
            case .fieldCount(let n): "A cron expression has 5 fields (minute hour day month weekday); this one has \(n)."
            case .invalidField(let f): "“\(f)” is not a valid cron field."
            case .tooManyIntervals(let n): "This schedule needs \(n) launchd calendar entries; use a simpler expression."
            }
        }
    }

    public let text: String
    public let minutes: [Int]
    public let hours: [Int]
    public let days: [Int]
    public let months: [Int]
    /// 0 = Sunday … 6 = Saturday.
    public let weekdays: [Int]
    let restricted: (minute: Bool, hour: Bool, day: Bool, month: Bool, weekday: Bool)

    public static func == (a: CronExpression, b: CronExpression) -> Bool { a.text == b.text }
    public func hash(into hasher: inout Hasher) { hasher.combine(text) }

    public init(_ text: String) throws {
        let fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { throw ParseError.fieldCount(fields.count) }
        self.text = fields.joined(separator: " ")
        let minute = try Self.parse(fields[0], 0...59)
        let hour = try Self.parse(fields[1], 0...23)
        let day = try Self.parse(fields[2], 1...31)
        let month = try Self.parse(fields[3], 1...12)
        let weekday = try Self.parse(fields[4], 0...7)
        minutes = minute.values
        hours = hour.values
        days = day.values
        months = month.values
        weekdays = Array(Set(weekday.values.map { $0 % 7 })).sorted()
        restricted = (minute.restricted, hour.restricted, day.restricted, month.restricted, weekday.restricted)
    }

    private static func parse(_ field: String, _ range: ClosedRange<Int>) throws -> (values: [Int], restricted: Bool) {
        var values = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            guard !part.isEmpty else { throw ParseError.invalidField(field) }
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard pieces.count <= 2 else { throw ParseError.invalidField(field) }
            var step = 1
            if pieces.count == 2 {
                guard let s = Int(pieces[1]), s > 0 else { throw ParseError.invalidField(field) }
                step = s
            }
            let base = pieces[0]
            var lower: Int, upper: Int
            if base == "*" {
                lower = range.lowerBound; upper = range.upperBound
            } else if let dash = base.firstIndex(of: "-") {
                guard let a = Int(base[..<dash]), let b = Int(base[base.index(after: dash)...]), a <= b else { throw ParseError.invalidField(field) }
                lower = a; upper = b
            } else {
                guard let a = Int(base) else { throw ParseError.invalidField(field) }
                lower = a
                upper = pieces.count == 2 ? range.upperBound : a
            }
            guard range.contains(lower), range.contains(upper) else { throw ParseError.invalidField(field) }
            values.formUnion(stride(from: lower, through: upper, by: step))
        }
        let all = Set(range)
        let isFull = field == "*" || values == all || (range == 0...7 && Set(values.map { $0 % 7 }) == Set(0...6))
        return (values.sorted(), !isFull)
    }

    func matchesDay(day: Int, month: Int, weekday: Int) -> Bool {
        guard months.contains(month) else { return false }
        switch (restricted.day, restricted.weekday) {
        case (true, true): return days.contains(day) || weekdays.contains(weekday)
        case (true, false): return days.contains(day)
        case (false, true): return weekdays.contains(weekday)
        case (false, false): return true
        }
    }

    /// The first matching minute strictly after `date`, looking up to eight years ahead.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard let start = calendar.date(byAdding: .minute, value: 1, to: date),
              var day = calendar.dateInterval(of: .day, for: start)?.start else { return nil }
        let first = calendar.dateComponents([.hour, .minute], from: start)
        var isFirstDay = true
        for _ in 0..<(366 * 8) {
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            if let d = c.day, let m = c.month, let w = c.weekday, matchesDay(day: d, month: m, weekday: w - 1) {
                for hour in hours {
                    if isFirstDay, hour < first.hour! { continue }
                    for minute in minutes {
                        if isFirstDay, hour == first.hour!, minute < first.minute! { continue }
                        var parts = DateComponents()
                        parts.year = c.year; parts.month = m; parts.day = d; parts.hour = hour; parts.minute = minute
                        if let candidate = calendar.date(from: parts), candidate > date { return candidate }
                    }
                }
            }
            isFirstDay = false
            guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = following
        }
        return nil
    }

    /// One dictionary per combination of the restricted fields (unrestricted ones are left out, meaning "every").
    public func launchdCalendarIntervals(limit: Int = 1000) throws -> [[String: Int]] {
        var base: [[String: Int]] = [[:]]
        func expand(_ key: String, _ values: [Int], _ isRestricted: Bool) {
            guard isRestricted else { return }
            base = base.flatMap { entry in values.map { value in entry.merging([key: value]) { $1 } } }
        }
        expand("Minute", minutes, restricted.minute)
        expand("Hour", hours, restricted.hour)
        expand("Month", months, restricted.month)
        var result: [[String: Int]]
        switch (restricted.day, restricted.weekday) {
        case (true, true):
            // cron's either-day rule: one set of entries per day field.
            result = base.flatMap { e in days.map { e.merging(["Day": $0]) { $1 } } }
                + base.flatMap { e in weekdays.map { e.merging(["Weekday": $0]) { $1 } } }
        case (true, false): result = base.flatMap { e in days.map { e.merging(["Day": $0]) { $1 } } }
        case (false, true): result = base.flatMap { e in weekdays.map { e.merging(["Weekday": $0]) { $1 } } }
        case (false, false): result = base
        }
        guard result.count <= limit else { throw ParseError.tooManyIntervals(result.count) }
        return result
    }
}
