import CryptoKit
import Foundation

struct NoteLibrary: Codable, Equatable, Sendable {
    var version = 1
    var folders: [NoteFolder]
    var notes: [Note]

    private enum CodingKeys: String, CodingKey {
        case version, folders, notes
    }

    init(folders: [NoteFolder] = [], notes: [Note] = []) {
        self.folders = folders
        self.notes = notes
    }

    init(from decoder: any Decoder) throws {
        // Only an actual array takes the legacy path; malformed envelopes must not
        // fall back to an empty library and overwrite the original file.
        if var container = try? decoder.unkeyedContainer() {
            folders = []
            notes = []
            while !container.isAtEnd {
                notes.append(try container.decode(Note.self))
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "Unsupported note library version.")
        }
        folders = try container.decode([NoteFolder].self, forKey: .folders)
        notes = try container.decode([Note].self, forKey: .notes)
    }
}

extension NoteLibrary {
    private static func equivalent(_ first: Note?, _ second: Note?) -> Bool {
        guard var first, var second else { return first == second }
        first.richText = PortableFontAttribute.comparable(first.richText)
        second.richText = PortableFontAttribute.comparable(second.richText)
        return first == second
    }

    func hasSameContent(as other: NoteLibrary?) -> Bool {
        guard let other, version == other.version, folders == other.folders, notes.count == other.notes.count else { return false }
        return zip(notes, other.notes).allSatisfy { Self.equivalent($0, $1) }
    }

    func validate() throws {
        let folderIDs = Set(folders.map(\.id))
        guard version == 1, Set(notes.map(\.id)).count == notes.count,
            folderIDs.count == folders.count,
            folders.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
            notes.allSatisfy({ $0.folderID.map { folderIDs.contains($0) } ?? true })
        else { throw LibrarySyncError.invalidLibrary }
    }

    /// Three-way merge: independent edits combine, concurrent document edits keep both versions.
    func merging(_ remote: NoteLibrary, base: NoteLibrary?) throws -> NoteLibrary {
        try validate()
        try remote.validate()
        try base?.validate()
        let baseNotes = Dictionary(uniqueKeysWithValues: (base?.notes ?? []).map { ($0.id, $0) })
        let baseFolders = Dictionary(uniqueKeysWithValues: (base?.folders ?? []).map { ($0.id, $0) })
        var mergedFolders = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        for folder in remote.folders {
            if mergedFolders[folder.id] == nil || folder != baseFolders[folder.id] {
                mergedFolders[folder.id] = folder
            }
        }
        var mergedNotes = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        for incoming in remote.notes {
            guard let local = mergedNotes[incoming.id] else {
                mergedNotes[incoming.id] = incoming
                continue
            }
            if Self.equivalent(local, incoming) || Self.equivalent(incoming, baseNotes[incoming.id]) { continue }
            if !Self.equivalent(local, baseNotes[incoming.id]) {
                // Stable content-derived identity makes retries and concurrent imports idempotent.
                var copy = local
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                guard var payload = try JSONSerialization.jsonObject(with: encoder.encode(local)) as? [String: Any] else {
                    throw LibrarySyncError.invalidLibrary
                }
                payload["richText"] = try JSONSerialization.jsonObject(
                    with: PortableFontAttribute.fingerprint(local.richText), options: .fragmentsAllowed)
                let digest = Array(SHA256.hash(data: try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)))
                copy.id = UUID(
                    uuid: (
                        digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                        digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
                    ))
                if let existing = mergedNotes[copy.id], !Self.equivalent(existing, copy) { throw LibrarySyncError.invalidLibrary }
                mergedNotes[copy.id] = copy
            }
            mergedNotes[incoming.id] = incoming
        }
        let merged = NoteLibrary(
            folders: mergedFolders.values.sorted { $0.id.uuidString < $1.id.uuidString },
            notes: mergedNotes.values.sorted {
                $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
            })
        try merged.validate()
        return merged
    }
}
