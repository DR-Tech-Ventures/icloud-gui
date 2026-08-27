import Foundation

enum DateGrouping: String, CaseIterable, Identifiable {
    case day, month, year

    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return "Day"
        case .month: return "Month"
        case .year: return "Year"
        }
    }
}

/// A run of consecutive assets sharing a date bucket.
struct GroupedRange: Equatable {
    let key: String            // sortable: "2024-03-15" / "2024-03" / "2024"
    let range: Range<Int>      // indices into the (already sorted) input
}

private let groupingCalendar = Calendar.current

/// Sortable bucket key. Built from calendar components rather than a DateFormatter:
/// this runs once per asset across a whole library, where formatter overhead shows up.
func groupKey(_ date: Date?, _ grouping: DateGrouping) -> String {
    guard let date else { return "" }   // sorts last in either direction
    let c = groupingCalendar.dateComponents([.year, .month, .day], from: date)
    let y = c.year ?? 0, m = c.month ?? 0, d = c.day ?? 0
    switch grouping {
    case .year:  return String(format: "%04d", y)
    case .month: return String(format: "%04d-%02d", y, m)
    case .day:   return String(format: "%04d-%02d-%02d", y, m, d)
    }
}

/// Groups an already-sorted list into consecutive runs. O(n), single pass.
func groupConsecutive(dates: [Date?], grouping: DateGrouping) -> [GroupedRange] {
    guard !dates.isEmpty else { return [] }
    var out: [GroupedRange] = []
    var start = 0
    var current = groupKey(dates[0], grouping)

    for i in 1..<dates.count {
        let key = groupKey(dates[i], grouping)
        if key != current {
            out.append(GroupedRange(key: current, range: start..<i))
            start = i
            current = key
        }
    }
    out.append(GroupedRange(key: current, range: start..<dates.count))
    return out
}

private let dayLabelFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .none; return f
}()
private let monthLabelFormatter: DateFormatter = {
    let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMM yyyy"); return f
}()

/// Human label for a section header. Called once per section, not per asset.
func groupLabel(_ date: Date?, _ grouping: DateGrouping) -> String {
    guard let date else { return "Undated" }
    switch grouping {
    case .day:   return dayLabelFormatter.string(from: date)
    case .month: return monthLabelFormatter.string(from: date)
    case .year:  return String(groupingCalendar.component(.year, from: date))
    }
}
