import SwiftUI

/// 时间展示策略：近期事件用相对时间（"刚刚"/"5分钟前"），
/// 较早的事件直接显示日期，避免出现"3个月前""2年前"这类无用的相对描述。
///
/// All format templates feed `setLocalizedDateFormatFromTemplate` so the
/// glyphs ("月" / "日" / "年" vs ", " / ":") and the field order adapt to
/// the user's locale automatically — no need for separate zh/en formatters.
enum EventTime {
    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Hm")
        return f
    }()

    private static let monthDayTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MdHm")
        return f
    }()

    private static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMd")
        return f
    }()

    /// `createdAtMillis` 为毫秒级 Unix 时间戳。
    static func label(_ createdAtMillis: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: Double(createdAtMillis) / 1000)
        let interval = now.timeIntervalSince(date)
        let cal = Calendar.current

        if interval < 60 {
            return String(localized: "刚刚", comment: "Relative time, < 1 minute ago")
        }
        if interval < 3600 {
            let minutes = Int(interval / 60)
            return String(localized: "\(minutes) 分钟前",
                          comment: "Relative time, n minutes ago")
        }
        if cal.isDateInToday(date) {
            return timeOnly.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            return String(localized: "昨天 \(timeOnly.string(from: date))",
                          comment: "Yesterday at HH:MM")
        }
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            return monthDayTime.string(from: date)
        }
        return fullDate.string(from: date)
    }
}

extension View {
    /// 以事件时间策略展示某个毫秒时间戳。
    func eventTimeText(_ createdAtMillis: Int64) -> Text {
        Text(EventTime.label(createdAtMillis))
    }
}
