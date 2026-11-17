import Foundation

/// Translate only protocol-defined decisions, preserving the server's exact rule payload.
enum PermissionChoices {
    static func make(kind: PendingPrompt.Kind, params: [String: Any], hasFileChanges: Bool) -> [PendingPrompt.ApprovalChoice] {
        func choice(_ id: String, _ label: String, _ detail: String? = nil, result: [String: Any]) -> PendingPrompt.ApprovalChoice? {
            guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return nil }
            return .init(id: id, label: label, detail: detail, result: data)
        }
        if kind == .permissionsApproval {
            guard let permissions = params["permissions"] as? [String: Any],
                  !permissions.isEmpty, Set(permissions.keys).isSubset(of: ["network", "fileSystem"]) else { return [] }
            let granted = permissions.filter { !($0.value is NSNull) }
            guard !granted.isEmpty else { return [] }
            return [
                choice("turn", "Allow for this turn", "Grant the permissions shown above until this turn ends.", result: ["permissions": granted, "scope": "turn"]),
                choice("session", "Allow for this session", "Grant the permissions shown above for the rest of this session.", result: ["permissions": granted, "scope": "session"]),
                choice("decline", "Decline", "Do not grant any additional permissions.", result: ["permissions": [String: Any](), "scope": "turn"])
            ].compactMap { $0 }
        }
        guard kind == .commandApproval || kind == .fileApproval else { return [] }
        let hasContext = kind == .fileApproval ? hasFileChanges
            : ((params["command"] as? String)?.isEmpty == false || params["networkApprovalContext"] is [String: Any])
        let decisions: [Any]
        if let offered = params["availableDecisions"], !(offered is NSNull) {
            // An explicit list is authoritative, including an empty or unsupported list.
            guard let offered = offered as? [Any] else { return [] }
            decisions = offered
        } else {
            var defaults: [Any] = ["accept", "acceptForSession"]
            if kind == .commandApproval {
                if let rule = params["proposedExecpolicyAmendment"] as? [String], !rule.isEmpty {
                    defaults.append(["acceptWithExecpolicyAmendment": ["execpolicy_amendment": rule]])
                }
                for rule in params["proposedNetworkPolicyAmendments"] as? [[String: Any]] ?? [] {
                    defaults.append(["applyNetworkPolicyAmendment": ["network_policy_amendment": rule]])
                }
            }
            defaults.append(contentsOf: ["decline", "cancel"])
            decisions = defaults
        }
        var seen = Set<String>()
        return decisions.compactMap { decision in
            let result = ["decision": decision]
            let entry: PendingPrompt.ApprovalChoice?
            if let simple = decision as? String {
                switch simple {
                case "accept" where hasContext:
                    entry = choice(simple, "Allow once", result: result)
                case "acceptForSession" where hasContext:
                    let scope = (params["grantRoot"] as? String).map { "Allow writes under \($0) for this session." }
                        ?? "Approve this action for the rest of this session."
                    entry = choice(simple, "Allow for this session", scope, result: result)
                case "decline": entry = choice(simple, "Decline", "Deny this action and let Codex continue.", result: result)
                case "cancel": entry = choice(simple, "Cancel run", "Deny this action and interrupt the current turn.", result: result)
                default: entry = nil
                }
            } else if kind == .commandApproval, hasContext, let object = decision as? [String: Any], object.count == 1,
                      let amendment = object["acceptWithExecpolicyAmendment"] as? [String: Any], amendment.count == 1,
                      let prefix = amendment["execpolicy_amendment"] as? [String], !prefix.isEmpty,
                      prefix.allSatisfy({ !$0.isEmpty }) {
                // Render argument boundaries explicitly, without changing or broadening the prefix.
                let scope = prefix.map { String(reflecting: $0) }.joined(separator: " ")
                entry = choice("exec:" + scope, "Allow all commands of this type", "Save command prefix: \(scope)", result: result)
            } else if kind == .commandApproval, hasContext, let object = decision as? [String: Any], object.count == 1,
                      let amendment = object["applyNetworkPolicyAmendment"] as? [String: Any], amendment.count == 1,
                      let rule = amendment["network_policy_amendment"] as? [String: String], rule.count == 2,
                      let host = rule["host"], !host.isEmpty, let action = rule["action"], ["allow", "deny"].contains(action) {
                entry = choice("network:\(action):\(host)", action == "allow" ? "Always allow this host" : "Always deny this host",
                               "Save network rule: \(action) \(host)", result: result)
            } else { entry = nil }
            guard let entry, seen.insert(entry.id).inserted else { return nil }
            return entry
        }
    }
}
