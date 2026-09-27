import Foundation
import AppKit

typealias NotifFrame = NotifWire.Notification

extension NotifWire.Notification {
    static func decode(_ data: Data) -> NotifFrame? {
        var c = Cursor(data)
        guard let kind = c.u8() else { return nil }
        guard kind == NotifWire.kindRichV2 else { return nil }

        guard let title = c.lp16(),
              let subtitle = c.lp16(),
              let body = c.lp16(),
              let srcName = c.lp8(),
              let srcId = c.lp8(),
              let nid = c.lp8(),
              let thread = c.lp8(),
              let hasSound = c.u8(),
              let attrByte = c.u8(),
              let actionCount = c.u8()
        else { return nil }

        var actions: [Action] = []
        for _ in 0..<Int(actionCount) {
            guard let aid = c.lp8(),
                  let atitle = c.lp8(),
                  let atype = c.u8()
            else { return nil }
            switch atype {
            case NotifWire.ActionKind.background.rawValue:
                actions.append(.init(id: aid, title: atitle, type: .background))
            case NotifWire.ActionKind.textInput.rawValue:
                guard let placeholder = c.lp8() else { return nil }
                actions.append(.init(id: aid, title: atitle, type: .textInput(placeholder: placeholder)))
            case NotifWire.ActionKind.dismiss.rawValue:
                actions.append(.init(id: aid, title: atitle, type: .dismiss))
            default:
                actions.append(.init(id: aid, title: atitle, type: .unknown(atype)))
            }
        }

        guard let srcIcon = c.lp32(),
              let ctxIcon = c.lp32(),
              let attCount = c.u8()
        else { return nil }

        var attachments: [Attachment] = []
        for _ in 0..<Int(attCount) {
            guard let uti = c.lp8(),
                  let bytes = c.lp32()
            else { return nil }
            attachments.append(.init(uti: uti, data: bytes))
        }

        return NotifFrame(
            title: title, subtitle: subtitle, body: body,
            sourceName: srcName,
            sourceIdentifier: srcId, notificationIdentifier: nid,
            threadIdentifier: thread,
            hasSound: hasSound != 0,
            attributes: Attributes(rawValue: attrByte),
            actions: actions,
            sourceIcon: srcIcon, contextIcon: ctxIcon,
            attachments: attachments,
            receivedAt: Date()
        )
    }

    /// Best icon to show: prefer contextIcon (avatars beat app glyphs for messaging),
    /// fall back to sourceIcon, fall back to LaunchServices lookup on Mac.
    var displayIcon: NSImage? {
        if !contextIcon.isEmpty, let i = NSImage(data: contextIcon) { return i }
        if !sourceIcon.isEmpty,  let i = NSImage(data: sourceIcon)  { return i }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sourceIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}

private struct Cursor {
    private let data: Data
    private var i: Int = 0
    init(_ data: Data) { self.data = data }

    mutating func u8() -> UInt8? {
        guard i < data.count else { return nil }
        defer { i += 1 }
        return data[i]
    }
    mutating func u16() -> UInt16? {
        guard i + 1 < data.count else { return nil }
        defer { i += 2 }
        return UInt16(data[i]) << 8 | UInt16(data[i + 1])
    }
    mutating func u32() -> UInt32? {
        guard i + 3 < data.count else { return nil }
        defer { i += 4 }
        return UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
    }
    mutating func lp8() -> String? {
        guard let len = u8() else { return nil }
        return readString(Int(len))
    }
    mutating func lp16() -> String? {
        guard let len = u16() else { return nil }
        return readString(Int(len))
    }
    mutating func lp32() -> Data? {
        guard let len = u32() else { return nil }
        let n = Int(len)
        guard i + n <= data.count else { return nil }
        defer { i += n }
        return data.subdata(in: i..<i + n)
    }
    private mutating func readString(_ n: Int) -> String? {
        guard i + n <= data.count else { return nil }
        defer { i += n }
        return String(data: data.subdata(in: i..<i + n), encoding: .utf8)
    }
}
