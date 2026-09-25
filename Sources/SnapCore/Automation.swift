import CoreGraphics
import Foundation

/// Something another program asked Snap to do, through a `snap://` URL or the command line.
public enum AutomationCommand: Equatable {
    case capture(CaptureRequest)
    case pinClipboard
    case togglePins
    case whiteboard(transparent: Bool)
    case scanCode
    case replayHistory
    case nextPinGroup
}

public struct CaptureRequest: Equatable {
    public enum Area: Equatable {
        /// Let the user select, as with the hotkey.
        case interactive
        case fullScreen
        /// The last selection on the screen with the pointer.
        case last
        /// The frontmost window.
        case activeWindow
        /// Points, top-left origin of the main display (as in Snipaste's `--area`).
        case rect(CGRect)
    }

    public enum Output: Equatable {
        case clipboard
        case pin
        /// The save folder, with the usual file name.
        case quickSave
        case file(String)
    }

    public var area: Area
    /// Empty means the normal capture UI decides (only meaningful for `.interactive`).
    public var outputs: [Output]
    public var delay: Double

    public init(area: Area, outputs: [Output], delay: Double = 0) {
        self.area = area
        self.outputs = outputs
        self.delay = delay
    }

    /// A fixed area without outputs still has to go somewhere: the clipboard, like Snipaste's silent captures.
    public var effectiveOutputs: [Output] {
        outputs.isEmpty && area != .interactive ? [.clipboard] : outputs
    }
}

public enum Automation {
    public static let scheme = "snap"

    // MARK: URL

    /// `snap://capture?area=full|last|window|x,y,w,h&output=clipboard,pin,save&file=/path.png&delay=2`,
    /// `snap://pin`, `snap://toggle-pins`, `snap://whiteboard?transparent=1`, `snap://scan`, `snap://history`.
    public static func parse(_ url: URL) -> AutomationCommand? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let name = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? { items.first { $0.name.lowercased() == key }?.value }
        switch name {
        case "capture", "snip":
            guard let area = parseArea(value("area") ?? "") else { return nil }
            var outputs: [CaptureRequest.Output] = []
            for part in (value("output") ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
                switch part {
                case "clipboard", "copy": outputs.append(.clipboard)
                case "pin": outputs.append(.pin)
                case "save", "quick-save": outputs.append(.quickSave)
                case "": break
                default: return nil
                }
            }
            if let file = value("file"), !file.isEmpty { outputs.append(.file(file)) }
            let delay = Double(value("delay") ?? "") ?? 0
            return .capture(CaptureRequest(area: area, outputs: outputs, delay: max(0, min(delay, 60))))
        case "pin", "paste": return .pinClipboard
        case "toggle-pins", "toggle-images": return .togglePins
        case "whiteboard": return .whiteboard(transparent: ["1", "true", "yes"].contains(value("transparent")?.lowercased() ?? ""))
        case "transparent-whiteboard": return .whiteboard(transparent: true)
        case "scan", "barcode-scan": return .scanCode
        case "history", "replay": return .replayHistory
        case "next-group", "switch-group": return .nextPinGroup
        default: return nil
        }
    }

    /// A command typed in settings: a `snap://` link or a command line like `snip --full -o "pin;quick-save"`.
    public static func parse(command text: String) -> AutomationCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("\(scheme)://") {
            return URL(string: trimmed).flatMap(parse)
        }
        return parse(arguments: splitArguments(trimmed))
    }

    /// Splits on spaces, keeping "quoted parts" and 'quoted parts' together.
    public static func splitArguments(_ text: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasToken = true
            } else if ch == " " || ch == "\t" {
                if hasToken { args.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { args.append(current) }
        return args
    }

    static func parseArea(_ text: String) -> CaptureRequest.Area? {
        switch text.lowercased() {
        case "", "select", "interactive": return .interactive
        case "full", "screen": return .fullScreen
        case "last": return .last
        case "window", "active-window": return .activeWindow
        default:
            let numbers = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
            return .rect(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
        }
    }

    public static func url(for command: AutomationCommand) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        switch command {
        case let .capture(request):
            c.host = "capture"
            var items: [URLQueryItem] = []
            switch request.area {
            case .interactive: break
            case .fullScreen: items.append(URLQueryItem(name: "area", value: "full"))
            case .last: items.append(URLQueryItem(name: "area", value: "last"))
            case .activeWindow: items.append(URLQueryItem(name: "area", value: "window"))
            case let .rect(r):
                items.append(URLQueryItem(name: "area", value: [r.minX, r.minY, r.width, r.height].map { String(format: "%g", $0) }.joined(separator: ",")))
            }
            let simple = request.outputs.compactMap { output -> String? in
                switch output {
                case .clipboard: return "clipboard"
                case .pin: return "pin"
                case .quickSave: return "save"
                case .file: return nil
                }
            }
            if !simple.isEmpty { items.append(URLQueryItem(name: "output", value: simple.joined(separator: ","))) }
            for case let .file(path) in request.outputs { items.append(URLQueryItem(name: "file", value: path)) }
            if request.delay > 0 { items.append(URLQueryItem(name: "delay", value: String(format: "%g", request.delay))) }
            c.queryItems = items.isEmpty ? nil : items
        case .pinClipboard: c.host = "pin"
        case .togglePins: c.host = "toggle-pins"
        case let .whiteboard(transparent):
            c.host = "whiteboard"
            if transparent { c.queryItems = [URLQueryItem(name: "transparent", value: "1")] }
        case .scanCode: c.host = "scan"
        case .replayHistory: c.host = "history"
        case .nextPinGroup: c.host = "next-group"
        }
        return c.url!
    }

    // MARK: Command line

    /// Snipaste-style arguments (after the executable): `snip --full -o clipboard`, `snip --area 0 0 800 600 -o "pin;quick-save"`,
    /// `snip --delay 2`, `paste`, `toggle-images`, `whiteboard [--transparent]`, `transparent-whiteboard`, `barcode-scan`.
    /// Returns nil when the arguments are not an automation command.
    public static func parse(arguments args: [String]) -> AutomationCommand? {
        guard let name = args.first?.lowercased() else { return nil }
        let rest = Array(args.dropFirst())
        switch name {
        case "snip":
            var area = CaptureRequest.Area.interactive
            var outputs: [CaptureRequest.Output] = []
            var delay = 0.0
            var i = 0
            while i < rest.count {
                switch rest[i] {
                case "--full": area = .fullScreen
                case "--last": area = .last
                case "--active-window": area = .activeWindow
                case "--area":
                    guard i + 4 < rest.count, let x = Double(rest[i + 1]), let y = Double(rest[i + 2]),
                          let w = Double(rest[i + 3]), let h = Double(rest[i + 4]), w > 0, h > 0 else { return nil }
                    area = .rect(CGRect(x: x, y: y, width: w, height: h))
                    i += 4
                case "--delay":
                    guard i + 1 < rest.count, let d = Double(rest[i + 1]) else { return nil }
                    delay = max(0, min(d, 60))
                    i += 1
                case "-o", "--output":
                    guard i + 1 < rest.count else { return nil }
                    for part in rest[i + 1].split(separator: ";").map(String.init) where !part.isEmpty {
                        switch part.lowercased() {
                        case "clipboard": outputs.append(.clipboard)
                        case "pin": outputs.append(.pin)
                        case "quick-save": outputs.append(.quickSave)
                        default: outputs.append(.file(part))
                        }
                    }
                    i += 1
                default:
                    return nil
                }
                i += 1
            }
            return .capture(CaptureRequest(area: area, outputs: outputs, delay: delay))
        case "paste": return .pinClipboard
        case "toggle-images": return .togglePins
        case "whiteboard": return .whiteboard(transparent: rest.contains("--transparent"))
        case "transparent-whiteboard": return .whiteboard(transparent: true)
        case "barcode-scan": return .scanCode
        case "switch-group": return .nextPinGroup
        default: return nil
        }
    }
}
