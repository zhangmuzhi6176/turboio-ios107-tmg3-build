import Foundation

// Text structure only: microphone capture, ASR, speaker diarization, storage and
// retention/deletion are not implemented here. There is no audio or AI summary
// field. Recognized text is immutable and is never replaced by a summary.
enum IOConversationError: Error, Equatable {
    case invalidLimits, invalidSessionTime, sessionTooLong, tooManySegments
    case invalidSegmentTime, segmentOutsideSession, outOfOrder, duplicateSegmentID
    case invalidText, segmentTextTooLarge, totalTextTooLarge
    case invalidSpeaker, invalidConfidence, invalidSearch
}

enum IOConversationBounds {
    static let maximumDurationMilliseconds: Int64 = 8 * 60 * 60 * 1_000
    static let maximumSegments = 10_000
    static let maximumTextBytes = 2 * 1_024 * 1_024
    static let defaultSegmentTextBytes = 64 * 1_024

    static func validateSegmentLimit(_ value: Int) throws {
        guard (1...maximumTextBytes).contains(value) else { throw IOConversationError.invalidLimits }
    }
}

struct IOConversationSegment: Identifiable, Equatable {
    let id: UUID
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let recognizedText: String
    // Anonymous, session-local labels only: speaker-1 ... speaker-999.
    // nil means unknown; the model never infers a person's identity.
    let speakerLabel: String?
    let confidence: Double?
    let unclear: Bool

    init(id: UUID = UUID(), startMilliseconds: Int64, endMilliseconds: Int64,
         recognizedText: String, speakerLabel: String? = nil, confidence: Double? = nil,
         unclear: Bool = false,
         maximumTextBytes: Int = IOConversationBounds.defaultSegmentTextBytes) throws {
        self.id = id
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.recognizedText = recognizedText
        self.speakerLabel = speakerLabel
        self.confidence = confidence
        self.unclear = unclear
        try validate(maximumTextBytes: maximumTextBytes)
    }

    fileprivate func validate(maximumTextBytes: Int) throws {
        try IOConversationBounds.validateSegmentLimit(maximumTextBytes)
        guard startMilliseconds >= 0, endMilliseconds >= startMilliseconds,
              endMilliseconds <= IOConversationBounds.maximumDurationMilliseconds else {
            throw IOConversationError.invalidSegmentTime
        }
        guard recognizedText.utf8.count <= maximumTextBytes else {
            throw IOConversationError.segmentTextTooLarge
        }
        // Keep ASR text byte-for-byte; only inspect whitespace, never trim it.
        let hasText = !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || (unclear && endMilliseconds > startMilliseconds) else {
            throw IOConversationError.invalidText
        }
        guard !recognizedText.unicodeScalars.contains(where: {
            ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127
        }) else { throw IOConversationError.invalidText }
        if let speakerLabel {
            let prefix = "speaker-"
            guard speakerLabel.hasPrefix(prefix) else { throw IOConversationError.invalidSpeaker }
            let digits = speakerLabel.dropFirst(prefix.count)
            guard (1...3).contains(digits.utf8.count), digits.first != "0",
                  digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(digits), (1...999).contains(number) else {
                throw IOConversationError.invalidSpeaker
            }
        }
        if let confidence {
            guard confidence.isFinite, (0...1).contains(confidence) else {
                throw IOConversationError.invalidConfidence
            }
        }
    }
}

struct IOConversationTextMatch: Equatable {
    let sessionID: UUID
    let segment: IOConversationSegment
    let startUTC: Date
    let endUTC: Date
}

struct IOConversationRecord: Identifiable, Equatable {
    let id: UUID
    // Date represents an absolute instant, independent of display timezone.
    let startedAtUTC: Date
    let endedAtUTC: Date
    let segments: [IOConversationSegment]
    let maximumSegmentTextBytes: Int

    init(id: UUID = UUID(), startedAtUTC: Date, endedAtUTC: Date,
         segments: [IOConversationSegment],
         maximumSegmentTextBytes: Int = IOConversationBounds.defaultSegmentTextBytes) throws {
        try IOConversationBounds.validateSegmentLimit(maximumSegmentTextBytes)
        let duration = endedAtUTC.timeIntervalSince(startedAtUTC)
        guard startedAtUTC.timeIntervalSince1970.isFinite, endedAtUTC.timeIntervalSince1970.isFinite,
              duration.isFinite, duration >= 0 else { throw IOConversationError.invalidSessionTime }
        guard duration <= Double(IOConversationBounds.maximumDurationMilliseconds) / 1_000 else {
            throw IOConversationError.sessionTooLong
        }
        guard segments.count <= IOConversationBounds.maximumSegments else {
            throw IOConversationError.tooManySegments
        }
        var previousStart: Int64 = -1
        var identifiers = Set<UUID>()
        var totalBytes = 0
        for segment in segments {
            try segment.validate(maximumTextBytes: maximumSegmentTextBytes)
            guard identifiers.insert(segment.id).inserted else { throw IOConversationError.duplicateSegmentID }
            // Overlapping speakers are possible; require start order, preserve
            // equal-start input order, and never silently sort the original.
            guard segment.startMilliseconds >= previousStart else { throw IOConversationError.outOfOrder }
            // A microsecond tolerance covers Date's binary fractional precision;
            // a full millisecond outside the session is always rejected.
            guard Double(segment.endMilliseconds) <= duration * 1_000 + 0.001 else {
                throw IOConversationError.segmentOutsideSession
            }
            let byteCount = segment.recognizedText.utf8.count
            guard byteCount <= IOConversationBounds.maximumTextBytes - totalBytes else {
                throw IOConversationError.totalTextTooLarge
            }
            totalBytes += byteCount
            previousStart = segment.startMilliseconds
        }
        self.id = id
        self.startedAtUTC = startedAtUTC
        self.endedAtUTC = endedAtUTC
        self.segments = segments
        self.maximumSegmentTextBytes = maximumSegmentTextBytes
    }

    // Results contain the original segment and computable absolute times; there
    // is no generated excerpt, correction, inferred speaker or summary.
    func matches(containing query: String, limit: Int = 100) throws -> [IOConversationTextMatch] {
        guard (1...1_000).contains(limit), query.utf8.count <= 512,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IOConversationError.invalidSearch
        }
        var results: [IOConversationTextMatch] = []
        for segment in segments {
            guard segment.recognizedText.range(of: query, options: [.caseInsensitive],
                                               locale: Locale(identifier: "en_US_POSIX")) != nil else { continue }
            results.append(IOConversationTextMatch(
                sessionID: id, segment: segment,
                startUTC: startedAtUTC.addingTimeInterval(Double(segment.startMilliseconds) / 1_000),
                endUTC: startedAtUTC.addingTimeInterval(Double(segment.endMilliseconds) / 1_000)))
            if results.count == limit { break }
        }
        return results
    }
}
