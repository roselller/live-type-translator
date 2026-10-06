import Foundation

/// Inspect clipboard representations as inert bytes only. Importing HTML into
/// a web/attributed-text renderer can load remote resources. Never do that here.
enum SelectionStructure {
    static func requiresCellNavigation(text: String, html: Data?, rtf: Data?) -> Bool {
        // Plain-text table copies use tabs. A tab can also be indentation, but
        // without cell coordinates we cannot safely distinguish the two.
        if text.contains("\t") { return true }
        if let html, let markup = String(data: html, encoding: .isoLatin1),
           markup.replacingOccurrences(of: "\0", with: "").range(
            of: #"<(?:table|thead|tbody|tfoot|tr|td|th)(?=[\s/>])"#,
            options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if let rtf, let markup = String(data: rtf, encoding: .isoLatin1),
           markup.range(of: #"\\(?:trowd\b|cellx-?\d|nesttableprops\b|itap[1-9])"#,
                        options: .regularExpression) != nil { return true }
        return false
    }
}
