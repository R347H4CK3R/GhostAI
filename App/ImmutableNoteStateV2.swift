import Foundation
import CryptoKit

/// Unused, pure in-memory foundation for add/delete notes, not a wire format or v1 adapter.
/// Compatible states form an ACI join only while every required join fits its budgets.
/// Changed content under an existing UUID is a conflict, never an inferred edit/import.
enum ImmutableNoteStateV2 {
    struct Payload: Equatable {
        let project: String
        let text: String
        let source: String
        /// Original Foundation-reference binary64 bits. Never convert through Unix/JSON.
        let savedAtBits: UInt64

        static func == (a: Self, b: Self) -> Bool {
            a.project.utf8.elementsEqual(b.project.utf8)
                && a.text.utf8.elementsEqual(b.text.utf8)
                && a.source.utf8.elementsEqual(b.source.utf8)
                && a.savedAtBits == b.savedAtBits
        }
    }
    struct ContentKey: Hashable {
        let bytes: Data
        init(bytes: Data) throws {
            guard bytes.count == 32 else { throw Failure.invalidKey }
            self.bytes = bytes
        }
        var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
    }
    struct Record: Equatable {
        let id: UUID
        let payload: Payload
    }
    struct Binding: Equatable {
        let id: UUID
        let contentKey: ContentKey
    }
    struct State: Equatable {
        let format: String
        let identityScheme: String
        let records: [Record]
        /// Retained for live AND known-deleted IDs. Absence on a tombstone means opaque.
        let bindings: [Binding]
        let tombstones: [UUID]

        init(format: String = "veyra-immutable-notes-v2", identityScheme: String = "note-payload-tlv-v2",
             records: [Record] = [], bindings: [Binding] = [], tombstones: [UUID] = []) {
            self.format = format; self.identityScheme = identityScheme
            self.records = records; self.bindings = bindings; self.tombstones = tombstones
        }
    }
    struct Limits {
        // A caller may lower these caps, never enlarge the established envelope.
        var maximumNotes = 10_000
        var maximumRecords = 30_000
        var maximumTombstones = 20_000
        var maximumDocumentBytes = 8 * 1_024 * 1_024
        var maximumJournalBytes = 17 * 1_024 * 1_024
        // Reservations from a future complete-document validator, not joined facts.
        var otherRecords = 0
        var otherTombstones = 0
        var otherDocumentBytes = 0
        var otherJournalBytes = 0
    }
    struct Usage: Equatable {
        let notes: Int
        let retainedBindings: Int
        let totalRecords: Int
        let totalTombstones: Int
        let noteDocumentReservationBytes: Int
        let noteJournalReservationBytes: Int
        let totalDocumentReservationBytes: Int
        let totalJournalReservationBytes: Int
    }
    struct Result: Equatable {
        let state: State
        let usage: Usage
    }
    enum Capacity: Equatable { case notes, records, tombstones, documentBytes, journalBytes, arithmetic }
    enum Failure: Error, Equatable {
        case invalidMetadata, invalidPayload, invalidDate, invalidKey, invalidHashLength, invalidLimits
        case duplicateRecord(UUID), duplicateBinding(UUID), duplicateTombstone(UUID), orphanBinding(UUID)
        case immutableConflict(UUID), contentCollision(ContentKey)
        case capacity(Capacity)
    }

    struct Engine {
        let limits: Limits
        private let digest: (Data) -> Data

        // Internal digest injection permits collision fault tests, not protocol negotiation.
        init(limits: Limits = Limits(), digest: @escaping (Data) -> Data = { Data(SHA256.hash(data: $0)) }) {
            self.limits = limits; self.digest = digest
        }

        /// Hash framing only, deliberately NOT the document/persistence serialization.
        /// Domain bytes then ordered TLVs: 1 project, 2 text, 3 source, 4 date bits.
        /// Each TLV is UInt8 tag || UInt64BE byte length || exact value bytes.
        func contentBytes(_ payload: Payload) throws -> Data {
            try validatePayload(payload)
            var bytes = Data("Veyra immutable note payload v2\0".utf8)
            func append(_ tag: UInt8, _ value: Data) throws {
                guard let length = UInt64(exactly: value.count) else { throw Failure.capacity(.arithmetic) }
                bytes.append(tag); bytes.append(bigEndian(length)); bytes.append(value)
            }
            try append(1, Data(payload.project.utf8))
            try append(2, Data(payload.text.utf8))
            try append(3, Data(payload.source.utf8))
            try append(4, bigEndian(payload.savedAtBits))
            return bytes
        }

        func contentKey(_ payload: Payload) throws -> ContentKey {
            let result = digest(try contentBytes(payload))
            guard result.count == 32 else { throw Failure.invalidHashLength }
            return try ContentKey(bytes: result)
        }

        func normalize(_ input: State) throws -> Result { try join([input]) }

        /// Validate ALL original candidates before suppressing ANY body. Never normalize
        /// each operand first: that would conceal conflicts/collisions in deleted bodies.
        /// Empty input is the identity for this unscoped component, not a complete vault.
        func join(_ inputs: [State]) throws -> Result {
            try validateLimits()
            let originals = try inputs.map(inspect)
            var bindings: [UUID: ContentKey] = [:]
            var records: [UUID: Record] = [:]
            var tombstones = Set<UUID>()
            for original in originals {
                tombstones.formUnion(original.tombstones)
                for (id, key) in original.bindings {
                    if let old = bindings[id], old != key { throw Failure.immutableConflict(id) }
                    bindings[id] = key
                }
                for (id, record) in original.records {
                    if let old = records[id], old.payload != record.payload { throw Failure.immutableConflict(id) }
                    records[id] = record
                }
            }
            // Full bodies remain available here, including every hidden candidate. A
            // digest match never licenses dropping a byte-unequal available payload.
            var payloads: [ContentKey: Payload] = [:]
            for (id, record) in records {
                // inspect established a binding for every record; no caller can forge it.
                guard let key = bindings[id] else { throw Failure.invalidMetadata }
                if let old = payloads[key], old != record.payload { throw Failure.contentCollision(key) }
                payloads[key] = record.payload
            }
            let state = State(records: records.values.filter { !tombstones.contains($0.id) }.sorted { uuidLess($0.id, $1.id) },
                              bindings: bindings.map { Binding(id: $0.key, contentKey: $0.value) }.sorted { uuidLess($0.id, $1.id) },
                              tombstones: tombstones.sorted(by: uuidLess))
            return Result(state: state, usage: try preflight(state))
        }

        private struct Facts {
            let records: [UUID: Record]
            let bindings: [UUID: ContentKey]
            let tombstones: Set<UUID>
        }

        private func inspect(_ input: State) throws -> Facts {
            guard input.format == "veyra-immutable-notes-v2", input.identityScheme == "note-payload-tlv-v2" else {
                throw Failure.invalidMetadata
            }
            var tombstones = Set<UUID>()
            for id in input.tombstones {
                guard tombstones.insert(id).inserted else { throw Failure.duplicateTombstone(id) }
            }
            var bindings: [UUID: ContentKey] = [:]
            for binding in input.bindings {
                guard bindings.updateValue(binding.contentKey, forKey: binding.id) == nil else {
                    throw Failure.duplicateBinding(binding.id)
                }
            }
            var records: [UUID: Record] = [:]
            var payloads: [ContentKey: Payload] = [:]
            for record in input.records {
                guard records.updateValue(record, forKey: record.id) == nil else { throw Failure.duplicateRecord(record.id) }
                let key = try contentKey(record.payload)
                if let old = bindings[record.id], old != key { throw Failure.immutableConflict(record.id) }
                bindings[record.id] = key
                if let old = payloads[key], old != record.payload { throw Failure.contentCollision(key) }
                payloads[key] = record.payload
            }
            for id in bindings.keys where records[id] == nil && !tombstones.contains(id) {
                throw Failure.orphanBinding(id)
            }
            // Include inferred bindings, all original bodies and all markers in the
            // original-state capacity check, even if deletion will hide those bodies.
            let original = State(records: input.records, bindings: bindings.map { Binding(id: $0.key, contentKey: $0.value) },
                                 tombstones: input.tombstones)
            _ = try preflight(original)
            return Facts(records: records, bindings: bindings, tombstones: tombstones)
        }

        private func validatePayload(_ payload: Payload) throws {
            let seconds = Double(bitPattern: payload.savedAtBits)
            guard seconds.isFinite, seconds >= -978_307_200, seconds <= 252_423_993_599 else { throw Failure.invalidDate }
            // Legacy field ceilings only. No trim, Unicode normalization, provenance
            // substitution, secret filtering or project-based deletion belongs in a join.
            guard !payload.project.isEmpty, payload.project.count <= 300,
                  payload.text.count <= 20_000, payload.source.count <= 2_000 else { throw Failure.invalidPayload }
        }

        private func validateLimits() throws {
            let caps = [limits.maximumNotes, limits.maximumRecords, limits.maximumTombstones,
                        limits.maximumDocumentBytes, limits.maximumJournalBytes]
            let ceilings = [10_000, 30_000, 20_000, 8 * 1_024 * 1_024, 17 * 1_024 * 1_024]
            guard zip(caps, ceilings).allSatisfy({ $0.0 >= 0 && $0.0 <= $0.1 }),
                  [limits.otherRecords, limits.otherTombstones, limits.otherDocumentBytes, limits.otherJournalBytes]
                    .allSatisfy({ $0 >= 0 }) else { throw Failure.invalidLimits }
        }

        private func preflight(_ state: State) throws -> Usage {
            // Conservative reservation ONLY, not encoded size or a codec guarantee.
            // 512 envelope + 256/record + 160/binding + 128/tombstone, and 6 per
            // exact UTF-8 payload byte (covers JSON escaping). Journal reserves two
            // such components. Future wire/encryption/journal overhead is separate.
            var bytes = 512
            bytes = try checkedAdd(bytes, checkedMultiply(state.records.count, 256))
            bytes = try checkedAdd(bytes, checkedMultiply(state.bindings.count, 160))
            bytes = try checkedAdd(bytes, checkedMultiply(state.tombstones.count, 128))
            for record in state.records {
                for field in [record.payload.project, record.payload.text, record.payload.source] {
                    bytes = try checkedAdd(bytes, checkedMultiply(field.utf8.count, 6))
                }
            }
            let journalBytes = try checkedMultiply(bytes, 2)
            let records = try checkedAdd(state.records.count, limits.otherRecords)
            let markers = try checkedAdd(state.tombstones.count, limits.otherTombstones)
            let document = try checkedAdd(bytes, limits.otherDocumentBytes)
            let journal = try checkedAdd(journalBytes, limits.otherJournalBytes)
            guard state.records.count <= limits.maximumNotes else { throw Failure.capacity(.notes) }
            guard records <= limits.maximumRecords else { throw Failure.capacity(.records) }
            guard markers <= limits.maximumTombstones else { throw Failure.capacity(.tombstones) }
            guard document <= limits.maximumDocumentBytes else { throw Failure.capacity(.documentBytes) }
            guard journal <= limits.maximumJournalBytes else { throw Failure.capacity(.journalBytes) }
            return Usage(notes: state.records.count, retainedBindings: state.bindings.count, totalRecords: records,
                         totalTombstones: markers, noteDocumentReservationBytes: bytes, noteJournalReservationBytes: journalBytes,
                         totalDocumentReservationBytes: document, totalJournalReservationBytes: journal)
        }
    }

    private static func bigEndian(_ value: UInt64) -> Data {
        Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private static func uuidBytes(_ id: UUID) -> Data {
        let u = id.uuid
        return Data([u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
    }
    private static func uuidLess(_ a: UUID, _ b: UUID) -> Bool { uuidBytes(a).lexicographicallyPrecedes(uuidBytes(b)) }
    private static func checkedAdd(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw Failure.capacity(.arithmetic) }
        return value
    }
    private static func checkedMultiply(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw Failure.capacity(.arithmetic) }
        return value
    }
}
