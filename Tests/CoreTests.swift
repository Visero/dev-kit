import Foundation

@main
struct CoreTests {
    static var passed=0
    static func check(_ name:String,_ condition:Bool) {
        guard condition else { print("FAIL: \(name)");exit(1) }
        passed+=1
    }
    static func rejects(_ name:String,_ action:() throws -> Void) {
        do { try action();print("FAIL: accepted invalid \(name)");exit(1) }
        catch { passed+=1 }
    }
    static func main() throws {
        let unchanged=try DiffEngine.compare("a\nb\n","a\nb\n")
        check("identical",unchanged.identical && unchanged.rows.count==3)
        check("empty",try DiffEngine.compare("","").identical)
        let inserted=try DiffEngine.compare("","hello")
        check("insert",inserted.added==1 && inserted.removed==0 && inserted.rows[0].rightNumber==1)
        let removed=try DiffEngine.compare("a\nb","")
        check("delete",removed.removed==2 && removed.added==0)
        let replaced=try DiffEngine.compare("a\nb\nc","a\nB\nx\nc")
        check("replace",replaced.added==2 && replaced.removed==1)
        check("aligned",replaced.rows[1].left=="b" && replaced.rows[1].right=="B")
        check("whitespace",try DiffEngine.compare("  a  ","a",ignoreWhitespace:true).identical)
        check("newline",!(try DiffEngine.compare("a","a\n").identical))
        check("CRLF",try DiffEngine.compare("a\r\nb","a\nb").identical)
        rejects("line cap") { _=try DiffEngine.compare(String(repeating:"a\n",count:4000),"") }
        // Deterministic reconstruction across varied repeated lines.
        var seed: UInt64=123456
        func next() -> Int { seed=seed &* 6364136223846793005 &+ 1;return Int((seed>>32)%7) }
        for index in 0..<150 {
            let a=(0..<(next()+1)).map { _ in String(next()) }.joined(separator:"\n")
            let b=(0..<(next()+1)).map { _ in String(next()) }.joined(separator:"\n")
            let r=try DiffEngine.compare(a,b)
            check("diff reconstruct \(index)",r.rows.compactMap(\.left).joined(separator:"\n")==a && r.rows.compactMap(\.right).joined(separator:"\n")==b)
        }
        let source=" { \"n\" : 9007199254740993, \"a\" : [true,null,\"汉字\\n文本\"], \"x\":-1.20e+30 } "
        let formatted=try JSONTools.format(source)
        check("large integer",formatted.contains("9007199254740993"))
        check("number token",formatted.contains("-1.20e+30"))
        check("key order",formatted.range(of:"\"n\"")!.lowerBound < formatted.range(of:"\"a\"")!.lowerBound)
        check("format idempotent",try JSONTools.format(formatted)==formatted)
        let compact=try JSONTools.format(source,compact:true)
        check("compact",compact=="{\"n\":9007199254740993,\"a\":[true,null,\"汉字\\n文本\"],\"x\":-1.20e+30}")
        check("empty object",try JSONTools.format("{}")=="{}")
        check("empty array",try JSONTools.format("[]")=="[]")
        check("top scalar",try JSONTools.format("true")=="true")
        check("string whitespace",try JSONTools.format("\" a b \"",compact:true)=="\" a b \"")
        check("duplicate keys preserved",try JSONTools.format("{\"x\":1,\"x\":2}",compact:true)=="{\"x\":1,\"x\":2}")
        check("huge exponent preserved",try JSONTools.format("1e9999")=="1e9999")
        for bad in [""," ","{x:1}","{'a':1}","[1,]","{\"a\":1,}","01","+1",".2","1.","1e","NaN","Infinity","true false","/* x */{}","\"\\q\"","\"unterminated","\"line\nnew\"","\"\\uD800\""] {
            rejects("JSON \(bad)") { _=try JSONTools.format(bad) }
        }
        rejects("depth") { _=try JSONTools.format(String(repeating:"[",count:130)+"0"+String(repeating:"]",count:130)) }
        do { _=try JSONTools.format("{\n\"a\": } ");exit(1) } catch let e as JSONIssue { check("error position",e.line==2 && e.column>1) }
        for (text,expected) in [("0",0),("+8",480),("-5",-300),("5.5",330),("+05:45",345),("-00:30",-30),("-12",-720),("14",840)] { check("offset \(text)",try TimeTools.offsetMinutes(text)==expected) }
        for invalid in ["","nan","inf","15","-13","5.555","1:60","-9223372036854775808:00","+14:01","2:-1"] { rejects("offset \(invalid)") { _=try TimeTools.offsetMinutes(invalid) } }
        check("epoch zero",TimeTools.formatted(try TimeTools.timestamp("0",unit:.seconds),minutes:0)=="1970-01-01 00:00:00.000")
        check("positive zone",TimeTools.formatted(try TimeTools.timestamp("0",unit:.seconds),minutes:480)=="1970-01-01 08:00:00.000")
        check("negative epoch",TimeTools.formatted(try TimeTools.timestamp("-1",unit:.seconds),minutes:0)=="1969-12-31 23:59:59.000")
        check("millisecond",TimeTools.formatted(try TimeTools.timestamp("1001",unit:.milliseconds),minutes:0)=="1970-01-01 00:00:01.001")
        check("reverse zero",TimeTools.epoch(try TimeTools.parseDate("1970-01-01 08:00:00",minutes:480),unit:.seconds)=="0")
        check("reverse millis",TimeTools.epoch(try TimeTools.parseDate("1970-01-01 00:00:01.123",minutes:0),unit:.milliseconds)=="1123")
        check("leap date",TimeTools.formatted(try TimeTools.parseDate("2024-02-29 12:30:00",minutes:0),minutes:0)=="2024-02-29 12:30:00.000")
        for invalid in ["2023-02-29 12:00:00","2024-13-01 00:00:00","2024-01-01 25:00:00",""] { rejects("date \(invalid)") { _=try TimeTools.parseDate(invalid,minutes:0) } }
        for invalid in ["","nan","inf","1e99","abc"] { rejects("epoch \(invalid)") { _=try TimeTools.timestamp(invalid,unit:.seconds) } }
        // Clock/countdown uses a single absolute instant and a fixed UTC+8 calendar.
        let iso = ISO8601DateFormatter()
        func moment(_ value: String) -> Date { iso.date(from:value)! }
        check("default work end",try WorkdayCountdown.parseTime("20:30")==1230)
        check("midnight work end",try WorkdayCountdown.parseTime("00:00")==0)
        check("last minute work end",try WorkdayCountdown.parseTime("23:59")==1439)
        check("trim work end",try WorkdayCountdown.parseTime(" 20:30 \n")==1230)
        for invalid in ["", "20:60", "24:00", "8:30", "20:3", "-1:00", "20:30:00", "ab:cd", "２０:３０"] {
            rejects("work end \(invalid)") { _=try WorkdayCountdown.parseTime(invalid) }
        }
        let oneSecondBefore = moment("2026-11-02T12:29:59Z")
        check("work end minus one second",WorkdayCountdown.state(at:oneSecondBefore) == .counting(seconds:1))
        check("round fraction upward",WorkdayCountdown.state(at:oneSecondBefore.addingTimeInterval(0.8)) == .counting(seconds:1))
        check("at work end",WorkdayCountdown.state(at:moment("2026-11-02T12:30:00Z")) == .offWork)
        check("after work",WorkdayCountdown.state(at:moment("2026-11-02T15:59:59Z")) == .offWork)
        check("new workday midnight",WorkdayCountdown.state(at:moment("2026-11-02T16:00:00Z")) == .counting(seconds:73800))
        check("Friday evening",WorkdayCountdown.state(at:moment("2026-11-06T15:59:59Z")) == .offWork)
        check("UTC Friday but Beijing Saturday",WorkdayCountdown.state(at:moment("2026-11-06T16:00:00Z")) == .restDay)
        check("Sunday rest",WorkdayCountdown.state(at:moment("2026-11-08T12:00:00Z")) == .restDay)
        check("UTC Sunday but Beijing Monday",WorkdayCountdown.state(at:moment("2026-11-08T16:00:00Z")) == .counting(seconds:73800))
        check("custom work end",WorkdayCountdown.state(at:moment("2026-11-02T10:59:00Z"),targetMinutes:1140) == .counting(seconds:60))
        check("invalid setting fallback",WorkdayCountdown.state(at:oneSecondBefore,targetMinutes:1440) == .counting(seconds:1))
        check("00:00 already off",WorkdayCountdown.state(at:moment("2026-11-02T16:00:00Z"),targetMinutes:0) == .offWork)
        check("countdown formatting",WorkdayCountdownState.counting(seconds:73800).display == "20:30:00")
        check("countdown zero padding",WorkdayCountdownState.counting(seconds:1).display == "00:00:01")
        check("off work display",WorkdayCountdownState.offWork.display == "已下班")
        check("weekend display",WorkdayCountdownState.restDay.display == "休息日")
        let crossover = moment("2026-11-02T16:00:00Z")
        check("UTC0 clock date",TimeTools.formatted(crossover,minutes:0)=="2026-11-02 16:00:00.000")
        check("UTC8 clock next day",TimeTools.formatted(crossover,minutes:480)=="2026-11-03 00:00:00.000")
        print("PASS: \(passed) core assertions")
    }
}
