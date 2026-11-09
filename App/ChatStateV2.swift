import Foundation
import CryptoKit

/// Unused, in-memory foundation only. No v1 IDs, storage, transport or call sites use it.
/// ACI applies to compatible normalized states whose joins fit the supplied budgets.
enum ChatStateV2 {
    enum Role: String, Equatable { case user, assistant }

    struct Payload: Equatable {
        let project: String
        let role: Role
        let text: String
        // Swift String equality folds canonical Unicode equivalence. Identity must not.
        static func == (a: Self, b: Self) -> Bool {
            a.project.utf8.elementsEqual(b.project.utf8) && a.role == b.role && a.text.utf8.elementsEqual(b.text.utf8)
        }
    }

    struct ContentKey: Hashable, Comparable {
        let bytes: Data
        init(bytes: Data) throws {
            guard bytes.count == 32 else { throw Failure.invalidKey }
            self.bytes = bytes
        }
        init(hex: String) throws { try self.init(bytes: parseHex(hex, count: 32)) }
        var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
        static func < (a: Self, b: Self) -> Bool { a.bytes.lexicographicallyPrecedes(b.bytes) }
    }

    struct DateBits: Equatable {
        let rawValue: UInt64
        init(_ secondsSinceReferenceDate: Double) throws { try self.init(rawValue: secondsSinceReferenceDate.bitPattern) }
        init(rawValue: UInt64) throws {
            let value = Double(bitPattern: rawValue)
            // Foundation reference seconds. No Unix conversion/rounding, including subnormals.
            guard value.isFinite, value >= -978_307_200, value <= 252_423_993_599 else { throw Failure.invalidDate }
            self.rawValue = rawValue
        }
        init(hex: String) throws {
            let bytes = try parseHex(hex, count: 8)
            try self.init(rawValue: bytes.reduce(0) { ($0 << 8) | UInt64($1) })
        }
        var hex: String { String(format: "%016llx", rawValue) }
        var value: Double { Double(bitPattern: rawValue) }
        static func minimum(_ a: Self, _ b: Self) -> Self {
            if a.value < b.value { return a }
            if b.value < a.value { return b }
            return a.rawValue <= b.rawValue ? a : b
        }
    }

    struct OrderKey: Equatable, Comparable {
        let counter: UInt64
        let originID: UUID
        let batchID: UUID
        let sequence: UInt64
        static func < (a: Self, b: Self) -> Bool {
            if a.counter != b.counter { return a.counter < b.counter }
            if a.originID != b.originID { return uuidLess(a.originID, b.originID) }
            if a.batchID != b.batchID { return uuidLess(a.batchID, b.batchID) }
            return a.sequence < b.sequence
        }
    }

    struct Variant: Equatable {
        let contentKey: ContentKey
        let payload: Payload
        let dateBits: DateBits
    }
    struct Family: Equatable {
        let familyID: UUID
        let anchorContentKey: ContentKey
        let orderKey: OrderKey
        let variants: [Variant]
    }
    struct Reference: Hashable, Comparable {
        let familyID: UUID
        let contentKey: ContentKey
        let projectedID: UUID
        static func < (a: Self, b: Self) -> Bool {
            if a.familyID != b.familyID { return uuidLess(a.familyID, b.familyID) }
            if a.contentKey != b.contentKey { return a.contentKey < b.contentKey }
            return uuidLess(a.projectedID, b.projectedID)
        }
    }
    struct State: Equatable {
        let format: String
        let identityScheme: String
        let orderClock: UInt64
        let families: [Family]
        let familyDeletes: [UUID]
        let variantDeletes: [Reference]
        let chatTombstones: [UUID]
        init(format: String = "veyra-chat-families-v2", identityScheme: String = "chat-content-v2", orderClock: UInt64 = 0,
             families: [Family] = [], familyDeletes: [UUID] = [], variantDeletes: [Reference] = [], chatTombstones: [UUID] = []) {
            self.format = format; self.identityScheme = identityScheme; self.orderClock = orderClock
            self.families = families; self.familyDeletes = familyDeletes; self.variantDeletes = variantDeletes; self.chatTombstones = chatTombstones
        }
    }
    struct Limits {
        var maximumLiveVariants = 10_000
        var maximumRecords = 30_000
        var maximumFamilies = 30_000
        var maximumTombstones = 20_000
        var maximumDocumentBytes = 8 * 1_024 * 1_024
        var maximumJournalBytes = 17 * 1_024 * 1_024
        // Reservations from a future complete-document caller, not facts merged here.
        var otherRecords = 0
        var otherTombstones = 0
        var otherDocumentBytes = 0
        var otherJournalBytes = 0
    }
    struct Usage: Equatable {
        let liveVariants: Int
        let retainedRoots: Int
        let tombstones: Int
        let documentBytes: Int
        let journalBytes: Int
    }
    struct Validated: Equatable {
        let state: State
        let usage: Usage
        fileprivate let references: [UUID: [ContentKey: Reference]]
        fileprivate init(state: State, usage: Usage, references: [UUID: [ContentKey: Reference]]) {
            self.state = state; self.usage = usage; self.references = references
        }
    }
    struct Row: Equatable {
        let reference: Reference
        let payload: Payload
        let dateBits: DateBits
    }
    struct MutationResult {
        let state: Validated
        let addedIDs: Set<UUID>
        let addedVariantDeletes: Set<Reference>
        let addedFamilyDeletes: Set<UUID>
        let addedTombstones: Set<UUID>
    }
    enum Capacity: Equatable { case liveVariants, records, families, tombstones, documentBytes, journalBytes, orderClock, orderBatch, arithmetic }
    enum Failure: Error, Equatable {
        case invalidKey, invalidDate, invalidCounter, invalidHex, invalidHashLength, invalidLimits
        case invalidMetadata(String)
        case duplicateFamily(UUID), duplicateVariant(UUID, ContentKey), duplicateSelector(Reference)
        case missingAnchor(UUID), anchorConflict(UUID), contentCollision(ContentKey), identifierCollision(UUID)
        case unknownFamily(UUID), unknownReference(Reference)
        case capacity(Capacity)
    }

    struct Engine {
        let limits: Limits
        private let digest: (Data) -> Data
        // Hash injection is internal and exists only to exercise fail-closed collisions.
        init(limits: Limits = Limits(), digest: @escaping (Data) -> Data = { Data(SHA256.hash(data: $0)) }) {
            self.limits = limits; self.digest = digest
        }

        func contentBytes(_ payload: Payload) throws -> Data {
            var bytes = Data("Veyra chat content v2\0".utf8)
            for field in [payload.project, payload.role.rawValue, payload.text] {
                let raw = Data(field.utf8)
                guard let count = UInt64(exactly: raw.count) else { throw Failure.capacity(.arithmetic) }
                bytes.append(contentsOf: (0..<8).reversed().map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) })
                bytes.append(raw)
            }
            return bytes
        }
        func contentKey(_ payload: Payload) throws -> ContentKey { try ContentKey(bytes: hash(contentBytes(payload))) }
        func projectedID(familyID: UUID, anchor: ContentKey, key: ContentKey) throws -> UUID {
            if key == anchor { return familyID }
            var bytes = Data("Veyra chat variant identity v2\0".utf8)
            bytes.append(uuidBytes(familyID)); bytes.append(key.bytes)
            var output = Array(try hash(bytes).prefix(16))
            output[6] = (output[6] & 0x0f) | 0x80
            output[8] = (output[8] & 0x3f) | 0x80
            return UUID(uuid: (output[0], output[1], output[2], output[3], output[4], output[5], output[6], output[7],
                               output[8], output[9], output[10], output[11], output[12], output[13], output[14], output[15]))
        }
        private func hash(_ bytes: Data) throws -> Data {
            let result = digest(bytes)
            guard result.count == 32 else { throw Failure.invalidHashLength }
            return result
        }
        private func reference(_ family: Family, _ key: ContentKey) throws -> Reference {
            Reference(familyID: family.familyID, contentKey: key,
                      projectedID: try projectedID(familyID: family.familyID, anchor: family.anchorContentKey, key: key))
        }

        /// Validates all bodies and identifiers BEFORE applying deletion normalization.
        /// Explicit delete facts may remove bodies, but cannot hide conflicts/collisions.
        func validate(_ input: State) throws -> Validated {
            try validateLimits()
            guard input.format == "veyra-chat-families-v2", input.identityScheme == "chat-content-v2" else {
                throw Failure.invalidMetadata("unsupported format or identity scheme")
            }
            var families: [UUID: Family] = [:]
            for family in input.families {
                guard families.updateValue(family, forKey: family.familyID) == nil else { throw Failure.duplicateFamily(family.familyID) }
            }
            let familyDeletes = Set(input.familyDeletes), tombstones = Set(input.chatTombstones)
            guard familyDeletes.count == input.familyDeletes.count, tombstones.count == input.chatTombstones.count else {
                throw Failure.invalidMetadata("duplicate deletion marker")
            }
            let roots = Set(families.keys).union(familyDeletes)
            var selectors = Set<Reference>()
            var owners: [UUID: Reference] = [:]
            var payloads: [ContentKey: Payload] = [:]
            func register(_ ref: Reference, in family: Family) throws {
                guard ref == (try reference(family, ref.contentKey)) else { throw Failure.invalidMetadata("incorrect projected ID") }
                if roots.contains(ref.projectedID), !(ref.projectedID == family.familyID && ref.contentKey == family.anchorContentKey) {
                    throw Failure.identifierCollision(ref.projectedID)
                }
                if let owner = owners[ref.projectedID], owner != ref { throw Failure.identifierCollision(ref.projectedID) }
                owners[ref.projectedID] = ref
            }
            for selector in input.variantDeletes {
                guard selectors.insert(selector).inserted else { throw Failure.duplicateSelector(selector) }
                guard let family = families[selector.familyID] else { throw Failure.unknownFamily(selector.familyID) }
                try register(selector, in: family)
            }
            // Marker aliases may not change delete scope. Every marker has a typed explanation.
            guard tombstones == familyDeletes.union(selectors.map(\.projectedID)) else {
                throw Failure.invalidMetadata("missing or unexplained chat tombstone")
            }
            var clock = input.orderClock
            for family in input.families {
                clock = max(clock, family.orderKey.counter)
                var keys = Set<ContentKey>()
                for variant in family.variants {
                    guard keys.insert(variant.contentKey).inserted else { throw Failure.duplicateVariant(family.familyID, variant.contentKey) }
                    guard try contentKey(variant.payload) == variant.contentKey else { throw Failure.invalidMetadata("payload key mismatch") }
                    if let body = payloads[variant.contentKey], body != variant.payload { throw Failure.contentCollision(variant.contentKey) }
                    payloads[variant.contentKey] = variant.payload
                    try register(reference(family, variant.contentKey), in: family)
                }
                let anchor = try reference(family, family.anchorContentKey)
                guard keys.contains(family.anchorContentKey) || familyDeletes.contains(family.familyID) || selectors.contains(anchor) else {
                    throw Failure.missingAnchor(family.familyID)
                }
            }
            // Normalize only after all original facts passed structural validation.
            var normalizedTombstones = tombstones
            var output: [Family] = []
            for family in input.families {
                var variants: [Variant] = []
                for variant in family.variants {
                    let ref = try reference(family, variant.contentKey)
                    if familyDeletes.contains(family.familyID) {
                        selectors.insert(ref); normalizedTombstones.insert(ref.projectedID)
                    }
                    if !selectors.contains(ref) { variants.append(variant) }
                }
                output.append(Family(familyID: family.familyID, anchorContentKey: family.anchorContentKey, orderKey: family.orderKey,
                                     variants: variants.sorted { $0.contentKey < $1.contentKey }))
            }
            let normalized = State(orderClock: clock, families: output.sorted { uuidLess($0.familyID, $1.familyID) },
                                   familyDeletes: familyDeletes.sorted(by: uuidLess), variantDeletes: selectors.sorted(),
                                   chatTombstones: normalizedTombstones.sorted(by: uuidLess))
            var references: [UUID: [ContentKey: Reference]] = [:]
            for family in normalized.families {
                var members: [ContentKey: Reference] = [:]
                for variant in family.variants { members[variant.contentKey] = try reference(family, variant.contentKey) }
                references[family.familyID] = members
            }
            return try Validated(state: normalized, usage: preflight(normalized), references: references)
        }

        func join(_ a: Validated, _ b: Validated) throws -> Validated {
            // Revalidation prevents a wrapper from another budget/hash context bypassing checks.
            let left = try validate(a.state), right = try validate(b.state)
            var byID = Dictionary(uniqueKeysWithValues: left.state.families.map { ($0.familyID, $0) })
            // Check all established anchors before constructing the candidate.
            for family in right.state.families {
                if let old = byID[family.familyID], old.anchorContentKey != family.anchorContentKey { throw Failure.anchorConflict(family.familyID) }
            }
            for family in right.state.families {
                guard let old = byID[family.familyID] else { byID[family.familyID] = family; continue }
                var variants = Dictionary(uniqueKeysWithValues: old.variants.map { ($0.contentKey, $0) })
                for variant in family.variants {
                    if let existing = variants[variant.contentKey] {
                        guard existing.payload == variant.payload else { throw Failure.contentCollision(variant.contentKey) }
                        variants[variant.contentKey] = Variant(contentKey: variant.contentKey, payload: existing.payload,
                                                               dateBits: DateBits.minimum(existing.dateBits, variant.dateBits))
                    } else { variants[variant.contentKey] = variant }
                }
                byID[family.familyID] = Family(familyID: family.familyID, anchorContentKey: family.anchorContentKey,
                                              orderKey: min(old.orderKey, family.orderKey), variants: Array(variants.values))
            }
            return try validate(State(orderClock: max(left.state.orderClock, right.state.orderClock), families: Array(byID.values),
                                      familyDeletes: Array(Set(left.state.familyDeletes).union(right.state.familyDeletes)),
                                      variantDeletes: Array(Set(left.state.variantDeletes).union(right.state.variantDeletes)),
                                      chatTombstones: Array(Set(left.state.chatTombstones).union(right.state.chatTombstones))))
        }

        /// Deterministic presentation only. Never feed rendered positions back into state.
        func project(_ value: Validated) -> [Row] {
            value.state.families.sorted {
                $0.orderKey != $1.orderKey ? $0.orderKey < $1.orderKey : uuidLess($0.familyID, $1.familyID)
            }.flatMap { family in
                family.variants.sorted {
                    if $0.contentKey == $1.contentKey { return false }
                    if $0.contentKey == family.anchorContentKey { return true }
                    if $1.contentKey == family.anchorContentKey { return false }
                    return $0.contentKey < $1.contentKey
                }.map { variant in
                    // Use the validated mapping, not this Engine's possibly different injected hash.
                    Row(reference: value.references[family.familyID]![variant.contentKey]!, payload: variant.payload, dateBits: variant.dateBits)
                }
            }
        }

        func newOrderBatch(clock: UInt64, originID: UUID, batchID: UUID, count: Int) throws -> [OrderKey] {
            try validateLimits()
            guard count > 0, count <= limits.maximumLiveVariants else { throw Failure.capacity(.orderBatch) }
            guard clock != UInt64.max else { throw Failure.capacity(.orderClock) }
            return (0..<count).map { OrderKey(counter: clock + 1, originID: originID, batchID: batchID, sequence: UInt64($0)) }
        }

        func observe(_ original: Validated, familyID: UUID, payload: Payload, dateBits: DateBits) throws -> MutationResult {
            let before = try validate(original.state)
            guard let family = before.state.families.first(where: { $0.familyID == familyID }) else { throw Failure.unknownFamily(familyID) }
            let key = try contentKey(payload)
            var variants = family.variants
            if let index = variants.firstIndex(where: { $0.contentKey == key }) {
                let old = variants[index]
                guard old.payload == payload else { throw Failure.contentCollision(key) }
                variants[index] = Variant(contentKey: key, payload: payload, dateBits: DateBits.minimum(old.dateBits, dateBits))
            } else { variants.append(Variant(contentKey: key, payload: payload, dateBits: dateBits)) }
            let changed = Family(familyID: familyID, anchorContentKey: family.anchorContentKey, orderKey: family.orderKey, variants: variants)
            let state = before.state
            let after = try validate(State(orderClock: state.orderClock, families: state.families.map { $0.familyID == familyID ? changed : $0 },
                                           familyDeletes: state.familyDeletes, variantDeletes: state.variantDeletes, chatTombstones: state.chatTombstones))
            return mutation(before, after)
        }

        func deleteVariants(_ original: Validated, references: Set<Reference>) throws -> MutationResult {
            let before = try validate(original.state)
            let known = Set(project(before).map(\.reference)).union(before.state.variantDeletes)
            for ref in references where !known.contains(ref) { throw Failure.unknownReference(ref) }
            let state = before.state
            let after = try validate(State(orderClock: state.orderClock, families: state.families, familyDeletes: state.familyDeletes,
                                           variantDeletes: Array(Set(state.variantDeletes).union(references)),
                                           chatTombstones: Array(Set(state.chatTombstones).union(references.map(\.projectedID)))))
            return mutation(before, after)
        }

        func deleteFamilies(_ original: Validated, familyIDs: Set<UUID>) throws -> MutationResult {
            let before = try validate(original.state)
            let known = Set(before.state.families.map(\.familyID)).union(before.state.familyDeletes)
            for id in familyIDs where !known.contains(id) { throw Failure.unknownFamily(id) }
            let state = before.state
            let after = try validate(State(orderClock: state.orderClock, families: state.families,
                                           familyDeletes: Array(Set(state.familyDeletes).union(familyIDs)), variantDeletes: state.variantDeletes,
                                           chatTombstones: Array(Set(state.chatTombstones).union(familyIDs))))
            return mutation(before, after)
        }

        private func mutation(_ before: Validated, _ after: Validated) -> MutationResult {
            MutationResult(state: after,
                           addedIDs: Set(project(after).map { $0.reference.projectedID }).subtracting(project(before).map { $0.reference.projectedID }),
                           addedVariantDeletes: Set(after.state.variantDeletes).subtracting(before.state.variantDeletes),
                           addedFamilyDeletes: Set(after.state.familyDeletes).subtracting(before.state.familyDeletes),
                           addedTombstones: Set(after.state.chatTombstones).subtracting(before.state.chatTombstones))
        }
        private func validateLimits() throws {
            guard [limits.maximumLiveVariants, limits.maximumRecords, limits.maximumFamilies, limits.maximumTombstones,
                   limits.maximumDocumentBytes, limits.maximumJournalBytes, limits.otherRecords, limits.otherTombstones,
                   limits.otherDocumentBytes, limits.otherJournalBytes].allSatisfy({ $0 >= 0 }) else { throw Failure.invalidLimits }
        }
        private func preflight(_ state: State) throws -> Usage {
            var live = 0
            // Conservative JSON upper bound, NOT a persisted codec. Includes names, delimiters,
            // hashes, canonical UUIDs, date hex and maximum 20-digit UInt64 decimal strings.
            // Six bytes per UTF-8 byte safely covers JSON escapes without normalization.
            var bytes = 512
            for family in state.families {
                bytes = try checkedAdd(bytes, 384)
                for variant in family.variants {
                    live = try checkedAdd(live, 1)
                    bytes = try checkedAdd(bytes, 256)
                    for field in [variant.payload.project, variant.payload.role.rawValue, variant.payload.text] {
                        bytes = try checkedAdd(bytes, checkedMultiply(field.utf8.count, 6))
                    }
                }
            }
            bytes = try checkedAdd(bytes, checkedMultiply(state.variantDeletes.count, 192))
            bytes = try checkedAdd(bytes, checkedMultiply(state.familyDeletes.count, 40))
            bytes = try checkedAdd(bytes, checkedMultiply(state.chatTombstones.count, 40))
            let roots = Set(state.families.map(\.familyID)).union(state.familyDeletes).count
            let markers = try checkedAdd(state.chatTombstones.count, limits.otherTombstones)
            let document = try checkedAdd(bytes, limits.otherDocumentBytes)
            let journal = try checkedAdd(checkedMultiply(bytes, 2), limits.otherJournalBytes)
            guard live <= limits.maximumLiveVariants else { throw Failure.capacity(.liveVariants) }
            guard try checkedAdd(live, limits.otherRecords) <= limits.maximumRecords else { throw Failure.capacity(.records) }
            guard roots <= limits.maximumFamilies else { throw Failure.capacity(.families) }
            guard markers <= limits.maximumTombstones else { throw Failure.capacity(.tombstones) }
            guard document <= limits.maximumDocumentBytes else { throw Failure.capacity(.documentBytes) }
            guard journal <= limits.maximumJournalBytes else { throw Failure.capacity(.journalBytes) }
            return Usage(liveVariants: live, retainedRoots: roots, tombstones: markers, documentBytes: document, journalBytes: journal)
        }
    }

    static func parseCounter(_ text: String) throws -> UInt64 {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 20, (bytes.count == 1 || bytes[0] != 48),
              bytes.allSatisfy({ $0 >= 48 && $0 <= 57 }), let value = UInt64(text) else { throw Failure.invalidCounter }
        return value
    }
    private static func parseHex(_ text: String, count: Int) throws -> Data {
        let chars = Array(text.utf8)
        guard chars.count == count * 2, chars.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
            throw Failure.invalidHex
        }
        func nibble(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : c - 87 }
        return Data(stride(from: 0, to: chars.count, by: 2).map { nibble(chars[$0]) * 16 + nibble(chars[$0 + 1]) })
    }
    static func uuidBytes(_ id: UUID) -> Data {
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
