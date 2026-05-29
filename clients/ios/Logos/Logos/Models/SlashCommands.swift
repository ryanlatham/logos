import Foundation

struct SlashCommandSpec: Identifiable, Hashable {
    let id: String
    let trigger: String
    let canonical: String
    let aliases: [String]
    let description: String
    let category: String
    let argsHint: String
    let subcommands: [String]
    let source: String
    let available: Bool
    let unavailableReason: String
    let requiresArgs: Bool
    let addsTrailingSpace: Bool
    let deprecated: Bool

    static func from(dictionary: [String: Any]) -> SlashCommandSpec? {
        guard let id = dictionary["id"] as? String,
              let trigger = normalizedSlash(dictionary["trigger"]),
              let canonical = normalizedSlash(dictionary["canonical"]),
              let description = dictionary["description"] as? String
        else { return nil }
        let aliases = (dictionary["aliases"] as? [String] ?? []).compactMap(normalizedSlash)
        return SlashCommandSpec(
            id: id,
            trigger: trigger,
            canonical: canonical,
            aliases: aliases,
            description: description,
            category: dictionary["category"] as? String ?? "Commands",
            argsHint: dictionary["args_hint"] as? String ?? "",
            subcommands: dictionary["subcommands"] as? [String] ?? [],
            source: dictionary["source"] as? String ?? "unknown",
            available: boolValue(dictionary["available"]) ?? true,
            unavailableReason: dictionary["unavailable_reason"] as? String ?? "",
            requiresArgs: boolValue(dictionary["requires_args"]) ?? false,
            addsTrailingSpace: boolValue(dictionary["adds_trailing_space"]) ?? false,
            deprecated: boolValue(dictionary["deprecated"]) ?? false
        )
    }

    func matches(_ query: String) -> SlashCommandMatch? {
        let token = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().dropFirstSlash
        guard token.isEmpty == false else { return SlashCommandMatch(score: available ? 4 : 14, matchedText: canonical) }
        let names = [canonical, trigger] + aliases
        var best: SlashCommandMatch?
        for name in names {
            let raw = name.lowercased().dropFirstSlash
            let score: Int?
            if raw == token {
                score = 0
            } else if raw.hasPrefix(token) {
                score = 1
            } else if raw.fuzzyContains(token) {
                score = 2
            } else {
                score = nil
            }
            if let score {
                let adjusted = score + (available ? 0 : 10)
                if best == nil || adjusted < best!.score {
                    best = SlashCommandMatch(score: adjusted, matchedText: name)
                }
            }
        }
        return best
    }

    private static func normalizedSlash(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}

struct SlashCommandMatch: Hashable {
    let score: Int
    let matchedText: String
}

struct SlashCommandCatalog: Equatable {
    let schemaVersion: Int
    let catalogVersion: String
    let generatedAt: String
    let fallbackUsed: Bool
    let commands: [SlashCommandSpec]
    let warnings: [String]

    static let empty = SlashCommandCatalog(
        schemaVersion: 1,
        catalogVersion: "empty",
        generatedAt: "",
        fallbackUsed: true,
        commands: [],
        warnings: []
    )

    static let fallback = SlashCommandCatalog(
        schemaVersion: 1,
        catalogVersion: "ios-fallback-v1",
        generatedAt: "",
        fallbackUsed: true,
        commands: [
            SlashCommandSpec(id: "fallback:resume", trigger: "/resume", canonical: "/resume", aliases: [], description: "Resume a previously-named session", category: "Session", argsHint: "[name]", subcommands: [], source: "fallback", available: true, unavailableReason: "", requiresArgs: false, addsTrailingSpace: true, deprecated: false),
            SlashCommandSpec(id: "fallback:title", trigger: "/title", canonical: "/title", aliases: [], description: "Set a title for the current session", category: "Session", argsHint: "[name]", subcommands: [], source: "fallback", available: true, unavailableReason: "", requiresArgs: false, addsTrailingSpace: true, deprecated: false),
            SlashCommandSpec(id: "fallback:queue", trigger: "/queue", canonical: "/queue", aliases: ["/q"], description: "Queue a prompt for the next turn", category: "Session", argsHint: "<prompt>", subcommands: [], source: "fallback", available: true, unavailableReason: "", requiresArgs: true, addsTrailingSpace: true, deprecated: false),
            SlashCommandSpec(id: "fallback:steer", trigger: "/steer", canonical: "/steer", aliases: [], description: "Inject a message after the next tool call", category: "Session", argsHint: "<prompt>", subcommands: [], source: "fallback", available: true, unavailableReason: "", requiresArgs: true, addsTrailingSpace: true, deprecated: false),
            SlashCommandSpec(id: "fallback:stop", trigger: "/stop", canonical: "/stop", aliases: [], description: "Stop the active run", category: "Session", argsHint: "", subcommands: [], source: "fallback", available: true, unavailableReason: "", requiresArgs: false, addsTrailingSpace: false, deprecated: false),
            SlashCommandSpec(id: "fallback:approve", trigger: "/approve", canonical: "/approve", aliases: [], description: "Approve a pending command", category: "Session", argsHint: "[session|always]", subcommands: [], source: "fallback", available: true, unavailableReason: "", requiresArgs: false, addsTrailingSpace: true, deprecated: false),
            SlashCommandSpec(id: "fallback:deny", trigger: "/deny", canonical: "/deny", aliases: [], description: "Deny a pending command", category: "Session", argsHint: "", subcommands: [], source: "fallback", available: true, unavailableReason: "", requiresArgs: false, addsTrailingSpace: false, deprecated: false),
            SlashCommandSpec(id: "fallback:status", trigger: "/status", canonical: "/status", aliases: [], description: "Show session info", category: "Session", argsHint: "", subcommands: [], source: "fallback", available: true, unavailableReason: "", requiresArgs: false, addsTrailingSpace: false, deprecated: false),
            SlashCommandSpec(id: "fallback:kanban", trigger: "/kanban", canonical: "/kanban", aliases: [], description: "Show or update the session kanban board", category: "Session", argsHint: "[status]", subcommands: [], source: "fallback", available: true, unavailableReason: "", requiresArgs: false, addsTrailingSpace: true, deprecated: false),
            SlashCommandSpec(id: "fallback:help", trigger: "/help", canonical: "/help", aliases: [], description: "Show gateway help", category: "Info", argsHint: "", subcommands: [], source: "fallback", available: true, unavailableReason: "", requiresArgs: false, addsTrailingSpace: false, deprecated: false),
            SlashCommandSpec(id: "fallback:commands", trigger: "/commands", canonical: "/commands", aliases: [], description: "List available slash commands", category: "Info", argsHint: "", subcommands: [], source: "fallback", available: true, unavailableReason: "", requiresArgs: false, addsTrailingSpace: false, deprecated: false)
        ],
        warnings: []
    )

    static func from(dictionary: [String: Any]) -> SlashCommandCatalog? {
        guard let catalogVersion = dictionary["catalog_version"] as? String else { return nil }
        let rawCommands = dictionary["commands"] as? [[String: Any]] ?? []
        return SlashCommandCatalog(
            schemaVersion: dictionary["schema_version"] as? Int ?? 1,
            catalogVersion: catalogVersion,
            generatedAt: dictionary["generated_at"] as? String ?? "",
            fallbackUsed: boolValue(dictionary["fallback_used"]) ?? false,
            commands: rawCommands.compactMap(SlashCommandSpec.from(dictionary:)),
            warnings: dictionary["warnings"] as? [String] ?? []
        )
    }

    func command(canonical: String) -> SlashCommandSpec? {
        commands.first { $0.canonical == canonical }
    }

    func replacementText(for command: SlashCommandSpec) -> String {
        command.canonical + (command.addsTrailingSpace ? " " : "")
    }

    func rankedCommands(for draft: String, recents: [String]) -> [SlashCommandSpec] {
        guard draft.hasPrefix("/") else { return [] }
        let scored = commands.compactMap { command -> (SlashCommandSpec, Int, Int)? in
            guard let match = command.matches(draft) else { return nil }
            let recentIndex = recents.firstIndex(of: command.canonical) ?? Int.max
            let recentBoost = draft == "/" && recentIndex != Int.max ? -10 + recentIndex : 0
            return (command, match.score + recentBoost, recentIndex)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
                return lhs.0.canonical < rhs.0.canonical
            }
            .map { $0.0 }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}

struct SlashCommandCompletionItem: Identifiable, Hashable {
    var id: String { "\(canonical):\(replacementStart):\(replacementEnd):\(replacementText)" }
    let canonical: String
    let replacementText: String
    let replacementStart: Int
    let replacementEnd: Int
    let display: String
    let detail: String
    let kind: String
    let addsTrailingSpace: Bool

    static func from(dictionary: [String: Any]) -> SlashCommandCompletionItem? {
        guard let canonical = dictionary["canonical"] as? String,
              let replacementText = dictionary["replacement_text"] as? String,
              let replacementStart = dictionary["replacement_start"] as? Int,
              let replacementEnd = dictionary["replacement_end"] as? Int
        else { return nil }
        return SlashCommandCompletionItem(
            canonical: canonical,
            replacementText: replacementText,
            replacementStart: replacementStart,
            replacementEnd: replacementEnd,
            display: dictionary["display"] as? String ?? canonical,
            detail: dictionary["detail"] as? String ?? "",
            kind: dictionary["kind"] as? String ?? "command",
            addsTrailingSpace: SlashCommandCatalog.boolValueForCompletion(dictionary["adds_trailing_space"]) ?? false
        )
    }
}

struct SlashCommandCompletionResult: Equatable {
    let catalogVersion: String
    let items: [SlashCommandCompletionItem]
    let fallbackUsed: Bool
    let warnings: [String]

    static let empty = SlashCommandCompletionResult(catalogVersion: "", items: [], fallbackUsed: false, warnings: [])

    static func from(dictionary: [String: Any]) -> SlashCommandCompletionResult? {
        guard let catalogVersion = dictionary["catalog_version"] as? String else { return nil }
        let rawItems = dictionary["items"] as? [[String: Any]] ?? []
        return SlashCommandCompletionResult(
            catalogVersion: catalogVersion,
            items: rawItems.compactMap(SlashCommandCompletionItem.from(dictionary:)),
            fallbackUsed: boolValue(dictionary["fallback_used"]) ?? false,
            warnings: dictionary["warnings"] as? [String] ?? []
        )
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}

private extension SlashCommandCatalog {
    static func boolValueForCompletion(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}

private extension String {
    var dropFirstSlash: String {
        hasPrefix("/") ? String(dropFirst()) : self
    }

    func fuzzyContains(_ needle: String) -> Bool {
        guard needle.isEmpty == false else { return true }
        var index = needle.startIndex
        for char in self where index < needle.endIndex {
            if char == needle[index] {
                index = needle.index(after: index)
            }
        }
        return index == needle.endIndex
    }
}
