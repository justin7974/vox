import Foundation

struct ActionDefinition {
    let id: String
    let name: String
    let triggers: [String]
    let type: ActionType
    let template: String?
    let params: [ParamDefinition]
    let description: String

    enum ActionType: String {
        case url
        case app
        case system
        case shortcut
        case vox
    }

    struct ParamDefinition {
        let name: String
        let type: String   // "string", "number"
        let required: Bool
    }
}

// MARK: - Markdown YAML Frontmatter Parser

extension ActionDefinition {
    /// Parse an ActionDefinition from a Markdown string with YAML frontmatter.
    /// Format:
    /// ```
    /// ---
    /// id: web_search
    /// name: Web 搜索
    /// type: url
    /// triggers:
    ///   - 搜索
    ///   - 搜一下
    /// template: https://google.com/search?q={query}
    /// params:
    ///   - name: query
    ///     type: string
    ///     required: true
    /// ---
    /// Description text here.
    /// ```
    static func parse(from markdown: String) throws -> ActionDefinition {
        // Split frontmatter from body
        let parts = markdown.components(separatedBy: "---")
        guard parts.count >= 3 else {
            throw VoxError.actionFailed("Invalid frontmatter: missing --- delimiters")
        }

        let yamlBlock = parts[1]
        let body = parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse YAML key-value pairs (simple line-based parser)
        let lines = yamlBlock.components(separatedBy: .newlines)

        var fields: [String: String] = [:]
        var triggers: [String] = []
        var params: [ParamDefinition] = []
        var currentList: String? = nil  // tracks which list we're collecting
        var currentParam: [String: String] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // List item under a key (e.g. "  - value")
            if trimmed.hasPrefix("- ") && currentList != nil {
                let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)

                if currentList == "triggers" {
                    triggers.append(value)
                } else if currentList == "params" {
                    // Param list items can be "- name: query" (start of new param)
                    // or continuation "  type: string"
                    if value.contains(": ") {
                        // This is "- name: query" style — start of a new param block
                        if !currentParam.isEmpty {
                            params.append(makeParam(from: currentParam))
                        }
                        currentParam = [:]
                        let kv = parseKeyValue(value)
                        if let kv = kv {
                            currentParam[kv.0] = kv.1
                        }
                    } else {
                        triggers.append(value) // fallback
                    }
                }
                continue
            }

            // Continuation of param fields (e.g. "    type: string")
            if currentList == "params" && line.hasPrefix("    ") && trimmed.contains(": ") {
                let kv = parseKeyValue(trimmed)
                if let kv = kv {
                    currentParam[kv.0] = kv.1
                }
                continue
            }

            // Top-level key: value
            if let kv = parseKeyValue(trimmed) {
                // Flush any pending param
                if currentList == "params" && !currentParam.isEmpty {
                    params.append(makeParam(from: currentParam))
                    currentParam = [:]
                }

                if kv.1.isEmpty {
                    // Key with no value = start of a list (triggers:, params:)
                    currentList = kv.0
                } else {
                    currentList = nil
                    fields[kv.0] = kv.1
                }
            }
        }

        // Flush last param if any
        if !currentParam.isEmpty {
            params.append(makeParam(from: currentParam))
        }

        // Validate required fields
        guard let id = fields["id"], !id.isEmpty else {
            throw VoxError.actionFailed("Action missing 'id' field")
        }
        guard let name = fields["name"], !name.isEmpty else {
            throw VoxError.actionFailed("Action '\(fields["id"] ?? "?")' missing 'name' field")
        }
        guard let typeStr = fields["type"], let actionType = ActionType(rawValue: typeStr) else {
            throw VoxError.actionFailed("Action '\(id)' has invalid or missing 'type'")
        }

        let description = body.isEmpty ? (fields["description"] ?? name) : body

        return ActionDefinition(
            id: id,
            name: name,
            triggers: triggers,
            type: actionType,
            template: fields["template"],
            params: params,
            description: description
        )
    }

    /// Parse a file at the given URL into an ActionDefinition.
    static func parse(fileAt url: URL) throws -> ActionDefinition {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parse(from: content)
    }

    // MARK: - Private helpers

    private static func parseKeyValue(_ str: String) -> (String, String)? {
        guard let colonRange = str.range(of: ":") else { return nil }
        let key = String(str[str.startIndex..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let value = String(str[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private static func makeParam(from dict: [String: String]) -> ParamDefinition {
        ParamDefinition(
            name: dict["name"] ?? "",
            type: dict["type"] ?? "string",
            required: dict["required"]?.lowercased() == "true"
        )
    }
}
