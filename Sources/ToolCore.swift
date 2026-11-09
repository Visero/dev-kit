import Foundation

enum KitError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// MARK: - Line diff (LCS, deterministic and bounded)
struct DiffRow: Identifiable, Sendable {
    let id: Int
    let leftNumber: Int?
    let rightNumber: Int?
    let left: String?
    let right: String?
    let changed: Bool
}
struct DiffResult: Sendable {
    let rows: [DiffRow]
    let added: Int
    let removed: Int
    var identical: Bool { added == 0 && removed == 0 }
}
enum DiffEngine {
    static func lines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    }
    static func compare(_ original: String, _ modified: String, ignoreWhitespace: Bool = false) throws -> DiffResult {
        guard original.utf8.count + modified.utf8.count <= 2_000_000 else { throw KitError.message("两侧文本合计不能超过 2 MB，请分段比较。") }
        let a = lines(original), b = lines(modified)
        guard a.count <= 4000 && b.count <= 4000 else { throw KitError.message("每侧最多支持 4,000 行，请分段比较。") }
        let normalize: (String) -> String = { ignoreWhitespace ? $0.trimmingCharacters(in: .whitespaces) : $0 }
        let na = a.map(normalize), nb = b.map(normalize)
        // Trim common prefix/suffix to keep everyday edits inexpensive.
        var prefix = 0
        while prefix < min(a.count,b.count) && na[prefix] == nb[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count,b.count)-prefix && na[a.count-1-suffix] == nb[b.count-1-suffix] { suffix += 1 }
        let n = a.count-prefix-suffix, m = b.count-prefix-suffix
        let cols = m+1
        var dp = [Int32](repeating: 0, count: (n+1)*(m+1))
        if n > 0 && m > 0 {
            for i in stride(from: n-1, through: 0, by: -1) {
                for j in stride(from: m-1, through: 0, by: -1) {
                    dp[i*cols+j] = na[prefix+i] == nb[prefix+j] ? 1 + dp[(i+1)*cols+j+1] : max(dp[(i+1)*cols+j],dp[i*cols+j+1])
                }
            }
        }
        enum Op { case same(Int,Int), delete(Int), insert(Int) }
        var ops: [Op] = (0..<prefix).map { .same($0,$0) }
        var i=0, j=0
        while i<n || j<m {
            if i<n && j<m && na[prefix+i] == nb[prefix+j] { ops.append(.same(prefix+i,prefix+j)); i+=1; j+=1 }
            else if i<n && (j==m || dp[(i+1)*cols+j] >= dp[i*cols+j+1]) { ops.append(.delete(prefix+i)); i+=1 }
            else { ops.append(.insert(prefix+j)); j+=1 }
        }
        for s in 0..<suffix { ops.append(.same(a.count-suffix+s,b.count-suffix+s)) }
        var rows: [DiffRow]=[], deletes: [Int]=[], inserts: [Int]=[]
        var added=0, removed=0
        func flush() {
            for k in 0..<max(deletes.count,inserts.count) {
                let l = k<deletes.count ? deletes[k] : nil, r = k<inserts.count ? inserts[k] : nil
                rows.append(DiffRow(id: rows.count,leftNumber: l.map{$0+1},rightNumber: r.map{$0+1},left: l.map{a[$0]},right: r.map{b[$0]},changed: true))
            }
            deletes.removeAll(keepingCapacity: true); inserts.removeAll(keepingCapacity: true)
        }
        for op in ops {
            switch op {
            case .same(let l,let r): flush(); rows.append(DiffRow(id:rows.count,leftNumber:l+1,rightNumber:r+1,left:a[l],right:b[r],changed:false))
            case .delete(let l): deletes.append(l); removed+=1
            case .insert(let r): inserts.append(r); added+=1
            }
        }
        flush()
        return DiffResult(rows: rows,added:added,removed:removed)
    }
}

// MARK: - Strict, lossless JSON formatter
// Never converts number tokens to Double: integers beyond 2^53 remain exact.
struct JSONIssue: LocalizedError {
    let message: String
    let line: Int
    let column: Int
    var errorDescription: String? { "第 \(line) 行，第 \(column) 列：\(message)" }
}
enum JSONTools {
    static func format(_ source: String, indent: String = "  ", compact: Bool = false) throws -> String {
        guard source.utf8.count <= 2_000_000 else { throw KitError.message("JSON 最多支持 2 MB，请减少输入内容。") }
        var parser = JSONParser(source)
        return try parser.run(indent:indent,compact:compact)
    }
}
private struct JSONParser {
    let bytes: [UInt8]
    var position = 0
    var tokens: [String] = []
    init(_ source: String) { bytes = Array(source.utf8) }
    var current: UInt8? { position<bytes.count ? bytes[position] : nil }
    mutating func whitespace() { while let b=current, b==32 || b==9 || b==10 || b==13 { position+=1 } }
    func issue(_ message: String) -> JSONIssue {
        let prefix=String(decoding: bytes.prefix(position),as: UTF8.self)
        let lines=prefix.components(separatedBy:"\n")
        return JSONIssue(message:message,line:lines.count,column:(lines.last?.count ?? 0)+1)
    }
    mutating func symbol(_ b: UInt8) throws {
        whitespace()
        guard current == b else { throw issue("应为 \(String(UnicodeScalar(b)))") }
        tokens.append(String(UnicodeScalar(b))); position+=1
    }
    mutating func string() throws {
        let start=position
        position+=1
        var escaped=false, closed=false
        while let b=current {
            if b < 32 { throw issue("字符串中包含未转义的控制字符") }
            position+=1
            if escaped { escaped=false }
            else if b==92 { escaped=true }
            else if b==34 { closed=true; break }
        }
        guard closed else { throw issue("字符串缺少结束引号") }
        let data=Data(bytes[start..<position])
        do { _ = try JSONDecoder().decode(String.self,from:data) }
        catch { throw issue("字符串转义或 Unicode 编码无效") }
        tokens.append(String(decoding:data,as:UTF8.self))
    }
    mutating func number() throws {
        let start=position
        if current==45 { position+=1 }
        if current==48 { position+=1; if let b=current, (48...57).contains(b) { throw issue("数字不能有前导零") } }
        else { guard let b=current, (49...57).contains(b) else { throw issue("无效数字") }; while let b=current,(48...57).contains(b) { position+=1 } }
        if current==46 { position+=1; guard let b=current,(48...57).contains(b) else { throw issue("小数点后需要数字") }; while let b=current,(48...57).contains(b) { position+=1 } }
        if current==101 || current==69 {
            position+=1
            if current==43 || current==45 { position+=1 }
            guard let b=current,(48...57).contains(b) else { throw issue("指数部分需要数字") }
            while let b=current,(48...57).contains(b) { position+=1 }
        }
        tokens.append(String(decoding:bytes[start..<position],as:UTF8.self))
    }
    mutating func value(depth: Int) throws {
        guard depth<=128 else { throw issue("嵌套不能超过 128 层") }
        whitespace()
        guard let b=current else { throw issue("请输入完整的 JSON 值") }
        switch b {
        case 123:
            try symbol(123); whitespace()
            if current==125 { try symbol(125); return }
            while true {
                whitespace(); guard current==34 else { throw issue("对象键名必须使用双引号") }
                try string(); try symbol(58); try value(depth:depth+1); whitespace()
                if current==125 { try symbol(125); return }
                try symbol(44)
            }
        case 91:
            try symbol(91); whitespace()
            if current==93 { try symbol(93); return }
            while true {
                try value(depth:depth+1); whitespace()
                if current==93 { try symbol(93); return }
                try symbol(44)
            }
        case 34: try string()
        case 45,48...57: try number()
        default:
            for literal in ["true","false","null"] {
                let chars=Array(literal.utf8)
                if bytes.count-position>=chars.count && Array(bytes[position..<position+chars.count])==chars {
                    position+=chars.count; tokens.append(literal); return
                }
            }
            throw issue("无效值；不支持注释、单引号或尾逗号")
        }
    }
    mutating func run(indent: String,compact: Bool) throws -> String {
        try value(depth:0); whitespace()
        guard position==bytes.count else { throw issue("JSON 值之后还有多余内容") }
        if compact { return tokens.joined() }
        var output="", level=0
        func padding(_ n: Int) -> String { String(repeating:indent,count:max(n,0)) }
        for (index,t) in tokens.enumerated() {
            let next=index+1<tokens.count ? tokens[index+1] : ""
            let prev=index>0 ? tokens[index-1] : ""
            switch t {
            case "{","[":
                output+=t; level+=1
                if next != "}" && next != "]" { output+="\n"+padding(level) }
            case "}","]":
                level-=1
                if prev != "{" && prev != "[" { output+="\n"+padding(level) }
                output+=t
            case ",": output+=",\n"+padding(level)
            case ":": output+=": "
            default: output+=t
            }
        }
        return output
    }
}

// MARK: - Weekly work schedule (fixed UTC+8; no holiday calendar)
enum WorkWeekday: Int, CaseIterable, Identifiable, Codable, Sendable {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday
    var id: Int { rawValue }
    var title: String { ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][rawValue] }
    static func at(_ date: Date) -> WorkWeekday {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: WorkdayCountdown.utcOffsetMinutes * 60)!
        return WorkWeekday(rawValue: (calendar.component(.weekday, from: date) + 5) % 7)!
    }
}

struct WorkDaySetting: Codable, Equatable, Sendable {
    var isWorkday: Bool
    var time: String
}

struct WorkWeekSchedule: Codable, Equatable, Sendable {
    /// Monday first, Sunday last. A rest day retains its time for later re-enabling.
    var days: [WorkDaySetting]

    static func migrated(legacyTime: String) -> WorkWeekSchedule {
        let time = (try? WorkdayCountdown.parseTime(legacyTime)) != nil
            ? legacyTime.trimmingCharacters(in: .whitespacesAndNewlines) : WorkdayCountdown.defaultTime
        return WorkWeekSchedule(days: WorkWeekday.allCases.map {
            WorkDaySetting(isWorkday: $0.rawValue < 5, time: time)
        })
    }
    static var standard: WorkWeekSchedule { migrated(legacyTime: WorkdayCountdown.defaultTime) }

    func validated() throws -> WorkWeekSchedule {
        guard days.count == 7 else { throw KitError.message("每周必须包含周一至周日的 7 项设置。") }
        var result = self
        for day in WorkWeekday.allCases {
            do { _ = try WorkdayCountdown.parseTime(days[day.rawValue].time) }
            catch {
                if !days[day.rawValue].isWorkday {
                    result.days[day.rawValue].time = WorkdayCountdown.defaultTime
                    continue
                }
                throw KitError.message("\(day.title)：请输入 24 小时制 HH:mm，例如 20:30。")
            }
            result.days[day.rawValue].time = days[day.rawValue].time.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    subscript(_ day: WorkWeekday) -> WorkDaySetting {
        get { days.indices.contains(day.rawValue) ? days[day.rawValue] : Self.standard.days[day.rawValue] }
        set {
            guard days.count == 7 else { return }
            days[day.rawValue] = newValue
        }
    }
}

enum WorkSchedulePreferences {
    static let key = "DevKit.workWeekSchedule"
    static let legacyKey = "DevKit.workEndTime"

    static func load(from defaults: UserDefaults = .standard) -> WorkWeekSchedule {
        if let data = defaults.data(forKey: key),
           let value = try? JSONDecoder().decode(WorkWeekSchedule.self, from: data),
           let valid = try? value.validated() { return valid }
        return .migrated(legacyTime: defaults.string(forKey: legacyKey) ?? WorkdayCountdown.defaultTime)
    }

    static func save(_ schedule: WorkWeekSchedule, to defaults: UserDefaults = .standard) throws {
        let valid = try schedule.validated()
        defaults.set(try JSONEncoder().encode(valid), forKey: key)
    }
}

// MARK: - Workday countdown
enum WorkdayCountdownState: Equatable {
    case counting(seconds: Int)
    case offWork
    case restDay

    var display: String {
        switch self {
        case .counting(let seconds):
            return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        case .offWork: return "已下班"
        case .restDay: return "休息日"
        }
    }
}
enum WorkdayCountdown {
    static let defaultTime = "20:30"
    static let defaultMinutes = 20 * 60 + 30
    static let utcOffsetMinutes = 480

    static func parseTime(_ text: String) throws -> Int {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ $0.count == 2 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else {
            throw KitError.message("请输入 24 小时制 HH:mm，例如 20:30。")
        }
        return hour * 60 + minute
    }

    static func state(at now: Date, targetMinutes: Int = defaultMinutes) -> WorkdayCountdownState {
        let minutes = (0..<1440).contains(targetMinutes) ? targetMinutes : defaultMinutes
        let time = String(format: "%02d:%02d", minutes / 60, minutes % 60)
        return state(at: now, schedule: .migrated(legacyTime: time))
    }

    static func state(at now: Date, schedule: WorkWeekSchedule) -> WorkdayCountdownState {
        let setting = schedule[WorkWeekday.at(now)]
        guard setting.isWorkday else { return .restDay }
        let minutes = (try? parseTime(setting.time)) ?? defaultMinutes
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: utcOffsetMinutes * 60)!
        let target = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(minutes * 60))
        guard now < target else { return .offWork }
        return .counting(seconds: Int(ceil(target.timeIntervalSince(now))))
    }
}

// MARK: - UTC offsets & Unix time
// Fixed UTC offsets, intentionally not city zones: no DST ambiguity.
enum EpochUnit: String, CaseIterable, Identifiable, Sendable {
    case seconds = "秒", milliseconds = "毫秒"
    var id: String { rawValue }
    var divisor: Double { self == .seconds ? 1 : 1000 }
}
enum TimeTools {
    static func offsetMinutes(_ text: String) throws -> Int {
        let raw=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !raw.isEmpty else { throw KitError.message("请输入 UTC 偏移，例如 0、8、-5 或 5.5。") }
        var hours: Double
        if raw.contains(":") {
            let parts=raw.split(separator:":",omittingEmptySubsequences:false)
            guard parts.count==2, let h=Int(parts[0]), (-12...14).contains(h), let m=Int(parts[1]), (0...59).contains(m), parts[1].count==2, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { throw KitError.message("偏移格式无效，例如 +05:30 或 -03:30。") }
            hours=(Double(abs(h))+Double(m)/60)*(raw.hasPrefix("-") ? -1 : 1)
        } else {
            guard let h=Double(raw),h.isFinite else { throw KitError.message("UTC 偏移必须是有效数字。") }
            hours=h
        }
        guard hours>=(-12) && hours<=14 else { throw KitError.message("UTC 偏移范围为 -12 到 +14。") }
        let minutes=hours*60
        guard abs(minutes-minutes.rounded())<0.000001 else { throw KitError.message("UTC 偏移精度最多到整分钟。") }
        return Int(minutes.rounded())
    }
    static func zoneLabel(_ minutes: Int) -> String {
        if minutes==0 { return "UTC+00:00" }
        return String(format:"UTC%@%02d:%02d",minutes<0 ? "−" : "+",abs(minutes)/60,abs(minutes)%60)
    }
    static func timestamp(_ input: String, unit: EpochUnit) throws -> Date {
        let text=input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty, let value=Double(text),value.isFinite else { throw KitError.message("请输入有效的 Unix 时间戳。") }
        let seconds=value/unit.divisor
        guard seconds >= -62135596800 && seconds <= 253402300799.999 else { throw KitError.message("时间戳超出可显示范围（公元 0001–9999 年）。") }
        return Date(timeIntervalSince1970:seconds)
    }
    static func formatter(_ minutes: Int, pattern: String="yyyy-MM-dd HH:mm:ss.SSS") -> DateFormatter {
        let f=DateFormatter()
        f.locale=Locale(identifier:"en_US_POSIX"); f.calendar=Calendar(identifier:.gregorian)
        f.timeZone=TimeZone(secondsFromGMT:minutes*60)!; f.dateFormat=pattern; f.isLenient=false
        return f
    }
    static func formatted(_ date: Date,minutes: Int) -> String { formatter(minutes).string(from:date) }
    static func parseDate(_ input: String,minutes: Int) throws -> Date {
        let text=input.trimmingCharacters(in:.whitespacesAndNewlines)
        for pattern in ["yyyy-MM-dd HH:mm:ss.SSS","yyyy-MM-dd HH:mm:ss"] {
            let f=formatter(minutes,pattern:pattern)
            if let date=f.date(from:text),f.string(from:date)==text { return date }
        }
        throw KitError.message("日期无效，请使用 yyyy-MM-dd HH:mm:ss，可附加 .SSS 毫秒。")
    }
    static func epoch(_ date: Date,unit: EpochUnit) -> String {
        let value=date.timeIntervalSince1970*unit.divisor
        if unit == .milliseconds { return String(format:"%.0f",value.rounded()) }
        if abs(value-value.rounded())<0.00001 { return String(format:"%.0f",value.rounded()) }
        return String(format:"%.3f",value)
    }
}
