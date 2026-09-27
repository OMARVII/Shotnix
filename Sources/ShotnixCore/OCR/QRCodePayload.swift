import Foundation

struct QRCodePayloadField: Hashable {
    let label: String
    let value: String
}

struct QRCodePayload: Hashable {
    let rawValue: String
    /// What the code holds, for a list of several ("Link", "Wi-Fi").
    let kind: String
    let title: String
    let detail: String
    let fields: [QRCodePayloadField]
    let actionTitle: String?
    let actionURL: URL?
    let copyValue: String

    var displayText: String {
        guard !fields.isEmpty else { return rawValue }
        return Self.lines(fields)
    }

    /// "Label: value" lines — shown, and copied, in the user's language.
    static func lines(_ fields: [QRCodePayloadField]) -> String {
        fields.map { field in L("\(field.label): \(field.value)") }.joined(separator: "\n")
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
                kind: L("Link"),
                title: L("Link QR found"),
                detail: url.host.map { host in L("Review the decoded link before opening: \(host)") } ?? L("Review the decoded link before opening."),
                fields: [QRCodePayloadField(label: L("URL"), value: trimmed)],
                actionTitle: L("Open Link"),
                actionURL: url,
                copyValue: trimmed
            )
        }

        return QRCodePayload(
            rawValue: trimmed,
            kind: L("Text"),
            title: L("Text QR found"),
            detail: L("Review the decoded text before copying."),
            fields: [QRCodePayloadField(label: L("Text"), value: trimmed)],
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
        if !to.isEmpty { fields.append(QRCodePayloadField(label: L("To"), value: to)) }
        if !subject.isEmpty { fields.append(QRCodePayloadField(label: L("Subject"), value: subject)) }
        if !message.isEmpty { fields.append(QRCodePayloadField(label: L("Message"), value: message)) }

        return QRCodePayload(
            rawValue: rawValue,
            kind: L("Email"),
            title: L("Email QR found"),
            detail: to.isEmpty ? L("Review the decoded email payload before copying.") : L("Review the email details before composing."),
            fields: fields.isEmpty ? [QRCodePayloadField(label: L("Email"), value: rawValue)] : fields,
            actionTitle: to.isEmpty ? nil : L("Compose Email"),
            actionURL: to.isEmpty ? nil : mailURL(to: to, subject: subject, body: message),
            copyValue: fields.isEmpty ? rawValue : lines(fields)
        )
    }

    private static func parseMailto(_ rawValue: String) -> QRCodePayload {
        let components = URLComponents(string: rawValue)
        let recipients = components?.path.removingPercentEncoding ?? String(rawValue.dropFirst("mailto:".count)).components(separatedBy: "?").first ?? ""
        let queryItems = components?.queryItems ?? []
        let subject = queryItems.first(where: { $0.name.lowercased() == "subject" })?.value ?? ""
        let body = queryItems.first(where: { $0.name.lowercased() == "body" })?.value ?? ""

        var fields = [QRCodePayloadField]()
        if !recipients.isEmpty { fields.append(QRCodePayloadField(label: L("To"), value: recipients)) }
        if !subject.isEmpty { fields.append(QRCodePayloadField(label: L("Subject"), value: subject)) }
        if !body.isEmpty { fields.append(QRCodePayloadField(label: L("Message"), value: body)) }

        return QRCodePayload(
            rawValue: rawValue,
            kind: L("Email"),
            title: L("Email QR found"),
            detail: recipients.isEmpty ? L("Review the decoded email payload before copying.") : L("Review the email details before composing."),
            fields: fields.isEmpty ? [QRCodePayloadField(label: L("Email"), value: rawValue)] : fields,
            actionTitle: recipients.isEmpty ? nil : L("Compose Email"),
            actionURL: URL(string: rawValue),
            copyValue: fields.isEmpty ? rawValue : lines(fields)
        )
    }

    private static func parsePhone(_ rawValue: String) -> QRCodePayload {
        let number = String(rawValue.dropFirst("tel:".count))
        return QRCodePayload(
            rawValue: rawValue,
            kind: L("Phone"),
            title: L("Phone QR found"),
            detail: L("Review the phone number before opening."),
            fields: [QRCodePayloadField(label: L("Phone"), value: number)],
            actionTitle: L("Call"),
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

        var fields = [QRCodePayloadField(label: L("To"), value: number)]
        if !message.isEmpty { fields.append(QRCodePayloadField(label: L("Message"), value: message)) }

        return QRCodePayload(
            rawValue: rawValue,
            kind: L("Message"),
            title: L("Message QR found"),
            detail: L("Review the message details before opening."),
            fields: fields,
            actionTitle: number.isEmpty ? nil : L("Open Messages"),
            actionURL: actionURL,
            copyValue: lines(fields)
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
        if !ssid.isEmpty { fields.append(QRCodePayloadField(label: L("Network"), value: ssid)) }
        if !security.isEmpty { fields.append(QRCodePayloadField(label: L("Security"), value: security)) }
        if !password.isEmpty, security.lowercased() != "nopass" { fields.append(QRCodePayloadField(label: L("Password"), value: password)) }
        if !hidden.isEmpty { fields.append(QRCodePayloadField(label: L("Hidden"), value: hidden)) }

        return QRCodePayload(
            rawValue: rawValue,
            kind: L("Wi-Fi"),
            title: L("Wi-Fi QR found"),
            detail: L("Review the network details before copying."),
            fields: fields.isEmpty ? [QRCodePayloadField(label: L("Wi-Fi"), value: rawValue)] : fields,
            actionTitle: nil,
            actionURL: nil,
            copyValue: fields.isEmpty ? rawValue : lines(fields)
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
