import Foundation
import Combine

/// All file reads are explicit; no directories, projects or network resources are scanned.
struct CodeFileSnapshot {
    static let maximumBytes = 10_000_000
    let text: String
    let encoding: String.Encoding
    let bom: Data
    let originalBytes: Data
    let uniformNewline: String?

    static func decode(_ data: Data) throws -> CodeFileSnapshot {
        guard data.count <= maximumBytes else { throw KitError.message("代码文件超过 10 MB，暂不打开。") }
        let bytes = [UInt8](data.prefix(4))
        let encoding: String.Encoding
        let count: Int
        if bytes.starts(with:[0xFF,0xFE,0x00,0x00]) { encoding = .utf32LittleEndian; count = 4 }
        else if bytes.starts(with:[0x00,0x00,0xFE,0xFF]) { encoding = .utf32BigEndian; count = 4 }
        else if bytes.starts(with:[0xEF,0xBB,0xBF]) { encoding = .utf8; count = 3 }
        else if bytes.starts(with:[0xFF,0xFE]) { encoding = .utf16LittleEndian; count = 2 }
        else if bytes.starts(with:[0xFE,0xFF]) { encoding = .utf16BigEndian; count = 2 }
        else { encoding = .utf8; count = 0 }
        guard let text = String(data:data.dropFirst(count),encoding:encoding),
              !text.unicodeScalars.contains(where:{ $0.value == 0 || ($0.value < 32 && ![9,10,13].contains($0.value)) }) else {
            throw KitError.message("不是可读取的代码文本。支持 UTF-8 及带 BOM 的 UTF-16/32；不会尝试乱码转换。")
        }
        return CodeFileSnapshot(text:text,encoding:encoding,bom:data.prefix(count),originalBytes:data,
                                uniformNewline:newlineStyle(text))
    }

    static func read(_ url: URL) throws -> CodeFileSnapshot {
        guard url.isFileURL else { throw KitError.message("只能打开本机文件。") }
        let values = try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        guard values.isRegularFile == true else { throw KitError.message("请选择代码文件，不能打开文件夹。") }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw KitError.message("代码文件超过 10 MB，暂不打开。") }
        return try decode(Data(contentsOf:url))
    }

    func encoded(_ current: String) throws -> Data {
        if current == text { return originalBytes }
        let output: String
        if let newline = uniformNewline {
            output = current.replacingOccurrences(of:"\r\n",with:"\n")
                .replacingOccurrences(of:"\r",with:"\n").replacingOccurrences(of:"\n",with:newline)
        } else { output = current }
        guard let bytes = output.data(using:encoding,allowLossyConversion:false),
              bytes.count + bom.count <= Self.maximumBytes else {
            throw KitError.message("无法按原编码保存，或内容超过 10 MB；编辑内容仍在窗口中。")
        }
        return bom + bytes
    }

    func checkUnchanged(at url: URL) throws {
        guard try Data(contentsOf:url) == originalBytes else {
            throw KitError.message("文件已被其他应用修改，已停止保存以免覆盖。请先复制当前编辑，再重新打开文件。")
        }
    }

    private static func newlineStyle(_ text: String) -> String? {
        let units = Array(text.utf16)
        var styles = Set<String>(), i = 0
        while i < units.count {
            if units[i] == 13 {
                if i + 1 < units.count && units[i+1] == 10 { styles.insert("\r\n");i += 1 }
                else { styles.insert("\r") }
            } else if units[i] == 10 { styles.insert("\n") }
            i += 1
        }
        return styles.count == 1 ? styles.first : nil
    }
}

struct CodeLineIndex {
    let starts: [Int]
    init(_ text: String) {
        let source = text as NSString
        var result = [0], offset = 0
        while offset < source.length {
            var end = 0, contentEnd = 0
            source.getLineStart(nil,end:&end,contentsEnd:&contentEnd,for:NSRange(location:offset,length:0))
            guard end > offset else { break }
            if contentEnd < end { result.append(end) }
            offset = end
        }
        starts = result
    }
    func lineIndex(at offset: Int) -> Int {
        var lower = 0, upper = starts.count
        while lower < upper {
            let middle = (lower+upper)/2
            if starts[middle] <= offset { lower = middle+1 } else { upper = middle }
        }
        return max(0,lower-1)
    }
}

enum CodeFileLanguage {
    static func resolve(_ url: URL, text: String) -> CodeLanguage {
        switch url.pathExtension.lowercased() {
        case "swift": return .swift
        case "js","mjs","cjs","jsx": return .javascript
        case "ts","tsx","mts","cts": return .typescript
        case "json","jsonc": return .json
        case "html","htm","xml","svg": return .html
        case "css","scss","less": return .css
        case "py","pyw": return .python
        case "go": return .go
        case "rs": return .rust
        case "java","kt","kts": return .java
        case "c","m": return .c
        case "cpp","cc","cxx","h","hpp","hh","mm": return .cpp
        case "sql": return .sql
        case "sh","bash","zsh","fish": return .shell
        default: return SyntaxLexer.resolved(.automatic,text:text)
        }
    }
}

final class RecentCodeFiles: ObservableObject {
    static let key = "DevKit.recentCodeFiles"
    static let limit = 5
    @Published private(set) var urls: [URL]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var seen = Set<String>()
        urls = (defaults.stringArray(forKey:Self.key) ?? []).filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath:$0).standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }.prefix(Self.limit).map { $0 }
    }
    func record(_ url: URL) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        urls = ([canonical] + urls.filter { $0 != canonical }).prefix(Self.limit).map { $0 }
        defaults.set(urls.map(\.path),forKey:Self.key)
    }
}
