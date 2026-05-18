import SwiftUI

/// 时间展示策略：近期事件用相对时间（"刚刚"/"5分钟前"），
/// 较早的事件直接显示日期，避免出现"3个月前""2年前"这类无用的相对描述。
enum EventTime {
    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    private static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    /// `createdAtMillis` 为毫秒级 Unix 时间戳。
    static func label(_ createdAtMillis: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: Double(createdAtMillis) / 1000)
        let interval = now.timeIntervalSince(date)
        let cal = Calendar.current

        // 未来时间或一分钟内
        if interval < 60 {
            return "刚刚"
        }
        // 一小时内
        if interval < 3600 {
            return "\(Int(interval / 60))分钟前"
        }
        // 今天：只显示时分
        if cal.isDateInToday(date) {
            return timeOnly.string(from: date)
        }
        // 昨天
        if cal.isDateInYesterday(date) {
            return "昨天 \(timeOnly.string(from: date))"
        }
        // 今年内：月日 + 时分
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            return monthDay.string(from: date)
        }
        // 更早：完整日期
        return fullDate.string(from: date)
    }
}

extension View {
    /// 以事件时间策略展示某个毫秒时间戳。
    func eventTimeText(_ createdAtMillis: Int64) -> Text {
        Text(EventTime.label(createdAtMillis))
    }
}
