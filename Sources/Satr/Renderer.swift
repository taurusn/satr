import Foundation

enum RendererError: LocalizedError {
    case missingResource(String)
    case unreadableResource(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            return "The renderer resource \(name) is missing."
        case .unreadableResource(let name):
            return "The renderer resource \(name) could not be read."
        }
    }
}

struct MarkdownRenderer {
    private let resourcesURL: URL

    init(bundle: Bundle = .main) throws {
        guard let resourceURL = bundle.resourceURL else {
            throw RendererError.missingResource("Resources")
        }
        resourcesURL = resourceURL
    }

    func render(markdown: String, fileName: String) throws -> String {
        var html = try resource(named: "reader.html")
        let replacements = [
            "__SATR_STYLES__": try resource(named: "reader.css"),
            "__SATR_MARKED__": scriptSafe(try resource(named: "marked.js")),
            "__SATR_PURIFY__": scriptSafe(try resource(named: "purify.min.js")),
            "__SATR_MERMAID__": scriptSafe(try resource(named: "mermaid.min.js")),
            "__SATR_READER__": scriptSafe(try resource(named: "reader.js")),
            "__SATR_MARKDOWN_B64__": Data(markdown.utf8).base64EncodedString(),
            "__SATR_FILENAME_B64__": Data(fileName.utf8).base64EncodedString()
        ]

        for (placeholder, value) in replacements {
            html = html.replacingOccurrences(of: placeholder, with: value)
        }
        return html
    }

    private func resource(named name: String) throws -> String {
        let url = resourcesURL.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RendererError.missingResource(name)
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw RendererError.unreadableResource(name)
        }
        return contents
    }

    private func scriptSafe(_ script: String) -> String {
        script.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
    }
}
