import Foundation

struct QRCodePayloadField: Hashable {
    let label: String
    let value: String
}

struct QRCodePayload: Hashable {
    let rawValue: String
    let title: String
    let detail: String
    let fields: [QRCodePayloadField]
    let actionTitle: String?
    let actionURL: URL?
    let copyValue: String

    var displayText: String {
        guard !fields.isEmpty else { return rawValue }
        return fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }

    static func parse(_ rawValue: String) -> QRCodePayload {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        if lowercased.hasPrefix("matmsg:") {
            return parseMATMSG(trimmed)
        }
        if lowercased.hasPrefix("mailto:") {
            return parseMailto(trimmed)
        }
        if lowercased.hasPrefix("tel:") {
            return parsePhone(trimmed)
        }
        if lowercased.hasPrefix("sms:") || lowercased.hasPrefix("smsto:") || lowercased.hasPrefix("mmsto:") {
            return parseMessage(trimmed)
        }
        if lowercased.hasPrefix("wifi:") {
            return parseWiFi(trimmed)
        }
        if let url = webURL(from: trimmed) {
            return QRCodePayload(
                rawValue: trimmed,
                title: "Link QR found",
                detail: url.host.map { "Review the decoded link before opening: \($0)" } ?? "Review the decoded link before opening.",
                fields: [QRCodePayloadField(label: "URL", value: trimmed)],
                actionTitle: "Open Link",
                actionURL: url,
                copyValue: trimmed
            )
        }

        return QRCodePayload(
            rawValue: trimmed,
            title: "Text QR found",
            detail: "Review the decoded text before copying.",
            fields: [QRCodePayloadField(label: "Text", value: trimmed)],
            actionTitle: nil,
            actionURL: nil,
            copyValue: trimmed
        )
    }

    private static func parseMATMSG(_ rawValue: String) -> QRCodePayload {
        let body = String(rawValue.dropFirst("MATMSG:".count))
        let fieldsByKey = keyedSemicolonFields(body)
        let to = fieldsByKey["TO"] ?? ""
        let subject = fieldsByKey["SUB"] ?? ""
        let message = fieldsByKey["BODY"] ?? ""
        var fields = [QRCodePayloadField]()
        if !to.isEmpty { fields.append(QRCodePayloadField(label: "To", value: to)) }
        if !subject.isEmpty { fields.append(QRCodePayloadField(label: "Subject", value: subject)) }
        if !message.isEmpty { fields.append(QRCodePayloadField(label: "Message", value: message)) }

        return QRCodePayload(
            rawValue: rawValue,
            title: "Email QR found",
            detail: to.isEmpty ? "Review the decoded email payload before copying." : "Review the email details before composing.",
            fields: fields.isEmpty ? [QRCodePayloadField(label: "Email", value: rawValue)] : fields,
            actionTitle: to.isEmpty ? nil : "Compose Email",
            actionURL: to.isEmpty ? nil : mailURL(to: to, subject: subject, body: message),
            copyValue: fields.isEmpty ? rawValue : fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        )
    }

    private static func parseMailto(_ rawValue: String) -> QRCodePayload {
        let components = URLComponents(string: rawValue)
        let recipients = components?.path.removingPercentEncoding ?? String(rawValue.dropFirst("mailto:".count)).components(separatedBy: "?").first ?? ""
        let queryItems = components?.queryItems ?? []
        let subject = queryItems.first(where: { $0.name.lowercased() == "subject" })?.value ?? ""
        let body = queryItems.first(where: { $0.name.lowercased() == "body" })?.value ?? ""

        var fields = [QRCodePayloadField]()
        if !recipients.isEmpty { fields.append(QRCodePayloadField(label: "To", value: recipients)) }
        if !subject.isEmpty { fields.append(QRCodePayloadField(label: "Subject", value: subject)) }
        if !body.isEmpty { fields.append(QRCodePayloadField(label: "Message", value: body)) }

        return QRCodePayload(
            rawValue: rawValue,
            title: "Email QR found",
            detail: recipients.isEmpty ? "Review the decoded email payload before copying." : "Review the email details before composing.",
            fields: fields.isEmpty ? [QRCodePayloadField(label: "Email", value: rawValue)] : fields,
            actionTitle: recipients.isEmpty ? nil : "Compose Email",
            actionURL: URL(string: rawValue),
            copyValue: fields.isEmpty ? rawValue : fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        )
    }

    private static func parsePhone(_ rawValue: String) -> QRCodePayload {
        let number = String(rawValue.dropFirst("tel:".count))
        return QRCodePayload(
            rawValue: rawValue,
            title: "Phone QR found",
            detail: "Review the phone number before opening.",
            fields: [QRCodePayloadField(label: "Phone", value: number)],
            actionTitle: "Call",
            actionURL: URL(string: rawValue),
            copyValue: number
        )
    }

    private static func parseMessage(_ rawValue: String) -> QRCodePayload {
        let lowercased = rawValue.lowercased()
        let number: String
        let message: String
        let actionURL: URL?

        if lowercased.hasPrefix("sms:") {
            let components = URLComponents(string: rawValue)
            number = components?.path ?? String(rawValue.dropFirst("sms:".count)).components(separatedBy: "?").first ?? ""
            message = components?.queryItems?.first(where: { $0.name.lowercased() == "body" })?.value ?? ""
            actionURL = URL(string: rawValue)
        } else {
            let schemeEnd = rawValue.firstIndex(of: ":") ?? rawValue.startIndex
            let remainder = String(rawValue[rawValue.index(after: schemeEnd)...])
            let pieces = remainder.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            number = pieces.first.map(String.init) ?? ""
            message = pieces.count > 1 ? String(pieces[1]) : ""
            actionURL = URL(string: "sms:\(number)")
        }

        var fields = [QRCodePayloadField(label: "To", value: number)]
        if !message.isEmpty { fields.append(QRCodePayloadField(label: "Message", value: message)) }

        return QRCodePayload(
            rawValue: rawValue,
            title: "Message QR found",
            detail: "Review the message details before opening.",
            fields: fields,
            actionTitle: number.isEmpty ? nil : "Open Messages",
            actionURL: actionURL,
            copyValue: fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        )
    }

    private static func parseWiFi(_ rawValue: String) -> QRCodePayload {
        let body = String(rawValue.dropFirst("WIFI:".count))
        let fieldsByKey = keyedEscapedSemicolonFields(body)
        let ssid = fieldsByKey["S"] ?? ""
        let security = fieldsByKey["T"] ?? ""
        let password = fieldsByKey["P"] ?? ""
        let hidden = fieldsByKey["H"] ?? ""

        var fields = [QRCodePayloadField]()
        if !ssid.isEmpty { fields.append(QRCodePayloadField(label: "Network", value: ssid)) }
        if !security.isEmpty { fields.append(QRCodePayloadField(label: "Security", value: security)) }
        if !password.isEmpty, security.lowercased() != "nopass" { fields.append(QRCodePayloadField(label: "Password", value: password)) }
        if !hidden.isEmpty { fields.append(QRCodePayloadField(label: "Hidden", value: hidden)) }

        return QRCodePayload(
            rawValue: rawValue,
            title: "Wi-Fi QR found",
            detail: "Review the network details before copying.",
            fields: fields.isEmpty ? [QRCodePayloadField(label: "Wi-Fi", value: rawValue)] : fields,
            actionTitle: nil,
            actionURL: nil,
            copyValue: fields.isEmpty ? rawValue : fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        )
    }

    private static func keyedSemicolonFields(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in body.split(separator: ";", omittingEmptySubsequences: true) {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = part[..<colon].uppercased()
            let value = String(part[part.index(after: colon)...])
            result[key] = value
        }
        return result
    }

    private static func keyedEscapedSemicolonFields(_ body: String) -> [String: String] {
        var fields: [String] = []
        var current = ""
        var isEscaped = false

        for character in body {
            if isEscaped {
                current.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == ";" {
                if !current.isEmpty { fields.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { fields.append(current) }

        var result: [String: String] = [:]
        for field in fields {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let key = field[..<colon].uppercased()
            let value = String(field[field.index(after: colon)...])
            result[key] = value
        }
        return result
    }

    private static func webURL(from payload: String) -> URL? {
        guard let components = URLComponents(string: payload),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              let url = components.url else {
            return nil
        }
        return url
    }

    private static func mailURL(to: String, subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to
        components.queryItems = [
            subject.isEmpty ? nil : URLQueryItem(name: "subject", value: subject),
            body.isEmpty ? nil : URLQueryItem(name: "body", value: body),
        ].compactMap { $0 }
        return components.url
    }
}
