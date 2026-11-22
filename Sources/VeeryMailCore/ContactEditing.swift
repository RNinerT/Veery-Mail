import Foundation

public struct ContactAddressBook: Identifiable, Sendable {
    public let id, name: String
    public let isDefault, canWrite: Bool

    public init(id: String, name: String, isDefault: Bool = false, canWrite: Bool = true) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.canWrite = canWrite
    }

    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String else { return nil }
        self.init(id: id, name: value["name"] as? String ?? "Address Book",
                  isDefault: value["isDefault"] as? Bool == true,
                  canWrite: (value["myRights"] as? [String: Any])?["mayWrite"] as? Bool == true)
    }
}

/// The editable fields of a JSContact card, with stable server keys for existing values.
public struct ContactEdit: Sendable {
    public struct Entry: Identifiable, Sendable {
        public let id: String
        public var value: String

        public init(id: String = UUID().uuidString, value: String = "") {
            self.id = id
            self.value = value
        }
    }

    public var name: String
    public var emails: [Entry] = []
    public var phones: [Entry] = []
    public var organizations: [Entry] = []
    public var notes: [Entry] = []
    let contactID: String?
    let state: String?
    private let hasName: Bool
    private let existingCollections: Set<String>

    public init(name: String = "", email: String = "") {
        self.name = name
        if !email.isEmpty { emails = [Entry(id: "main", value: email)] }
        contactID = nil
        state = nil
        hasName = false
        existingCollections = []
    }

    init(card: [String: Any], state: String) {
        contactID = card["id"] as? String
        self.state = state
        hasName = card["name"] is [String: Any]
        name = ContactCards.displayName(card["name"] as? [String: Any]) ?? ""
        existingCollections = Set(["emails", "phones", "organizations", "notes"].filter { card[$0] is [String: Any] })
        func entries(_ collection: String, _ field: String) -> [Entry] {
            (card[collection] as? [String: [String: Any]] ?? [:]).sorted { $0.key < $1.key }.compactMap { key, record in
                (record[field] as? String).map { Entry(id: key, value: $0) }
            }
        }
        emails = entries("emails", "address")
        phones = entries("phones", "number")
        organizations = entries("organizations", "name")
        notes = entries("notes", "note")
    }

    func patch(to edited: ContactEdit) -> [String: Any] {
        var patch: [String: Any] = [:]
        if edited.name != name {
            if hasName { patch["name/full"] = edited.name }
            else { patch["name"] = ["full": edited.name] }
        }

        func update(_ collection: String, field: String, _ original: [Entry], _ edited: [Entry]) {
            let old = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0.value) })
            let new = Dictionary(uniqueKeysWithValues: edited.map { ($0.id, $0.value) })
            if !existingCollections.contains(collection) {
                if !new.isEmpty { patch[collection] = new.mapValues { [field: $0] } }
                return
            }
            for (key, value) in new where old[key] != value {
                let path = collection + "/" + key.replacingOccurrences(of: "~", with: "~0")
                    .replacingOccurrences(of: "/", with: "~1")
                if old[key] == nil { patch[path] = [field: value] }
                else { patch[path + "/" + field] = value }
            }
            for key in old.keys where new[key] == nil {
                let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                patch[collection + "/" + escaped] = NSNull()
            }
        }

        update("emails", field: "address", emails, edited.emails)
        update("phones", field: "number", phones, edited.phones)
        update("organizations", field: "name", organizations, edited.organizations)
        update("notes", field: "note", notes, edited.notes)
        return patch
    }
}
