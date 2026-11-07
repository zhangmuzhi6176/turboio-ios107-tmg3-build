import XCTest
@testable import RayNeoCompanion

final class IOConversationRecordTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func segment(_ text: String = "原文", start: Int64 = 0, end: Int64 = 1_000,
                         speaker: String? = nil, confidence: Double? = nil,
                         unclear: Bool = false) throws -> IOConversationSegment {
        try IOConversationSegment(startMilliseconds: start, endMilliseconds: end,
                                  recognizedText: text, speakerLabel: speaker,
                                  confidence: confidence, unclear: unclear)
    }

    private func record(_ segments: [IOConversationSegment], seconds: Double = 60) throws -> IOConversationRecord {
        try IOConversationRecord(startedAtUTC: start, endedAtUTC: start.addingTimeInterval(seconds), segments: segments)
    }

    func testChineseSearchPreservesExactTextAndComputesUTC() throws {
        let original = "  今天讨论眼镜。👨‍👩‍👧‍👦 e\u{301}\r\n保留原文  "
        let first = try segment(original, start: 1_250, end: 3_750, speaker: "speaker-1", confidence: 0.8)
        let second = try segment("眼镜测试", start: 4_000, end: 5_000)
        let value = try record([first, second])
        let hits = try value.matches(containing: "眼镜")
        var hitIDs: [UUID] = []
        for hit in hits { hitIDs.append(hit.segment.id) }
        let expectedIDs: [UUID] = [first.id, second.id]
        XCTAssertEqual(hitIDs, expectedIDs)
        let actualBytes = Data(hits[0].segment.recognizedText.utf8)
        let originalBytes = Data(original.utf8)
        XCTAssertEqual(actualBytes, originalBytes)
        XCTAssertEqual(hits[0].sessionID, value.id)
        XCTAssertEqual(hits[0].startUTC, start.addingTimeInterval(1.25))
        XCTAssertEqual(hits[0].endUTC, start.addingTimeInterval(3.75))
        let limitedHits = try value.matches(containing: "眼镜", limit: 1)
        let missingHits = try value.matches(containing: "不存在")
        XCTAssertEqual(limitedHits.count, 1)
        XCTAssertTrue(missingHits.isEmpty)
    }

    func testTimeZonesDoNotChangeTheStoredInstants() throws {
        let formatter = ISO8601DateFormatter()
        let utc = try XCTUnwrap(formatter.date(from: "2026-11-07T00:00:00Z"))
        let shanghai = try XCTUnwrap(formatter.date(from: "2026-11-07T08:00:00+08:00"))
        XCTAssertEqual(utc, shanghai)
        let piece = try segment(start: 1_000, end: 2_000)
        let a = try IOConversationRecord(startedAtUTC: utc, endedAtUTC: utc.addingTimeInterval(3), segments: [piece])
        let b = try IOConversationRecord(id: a.id, startedAtUTC: shanghai,
                                         endedAtUTC: shanghai.addingTimeInterval(3), segments: [piece])
        XCTAssertEqual(a, b)
        let utcMatches = try a.matches(containing: "原文")
        let shanghaiMatches = try b.matches(containing: "原文")
        XCTAssertEqual(utcMatches, shanghaiMatches)
    }

    func testRejectsInvalidSessionAndSegmentTimes() throws {
        XCTAssertThrowsError(try record([], seconds: -1))
        let invalidDates: [Double] = [Double.nan, Double.infinity, -Double.infinity]
        for bad in invalidDates {
            let invalidDate = Date(timeIntervalSince1970: bad)
            XCTAssertThrowsError(try IOConversationRecord(startedAtUTC: invalidDate,
                                                           endedAtUTC: start, segments: []))
            XCTAssertThrowsError(try IOConversationRecord(startedAtUTC: start,
                                                           endedAtUTC: invalidDate, segments: []))
        }
        XCTAssertThrowsError(try segment(start: -1))
        XCTAssertThrowsError(try segment(start: 2_000, end: 1_000))
        XCTAssertThrowsError(try segment(end: Int64.max))
        let outside = try segment(end: 60_001)
        let boundary = try segment(end: 60_000)
        XCTAssertThrowsError(try record([outside]))
        XCTAssertNoThrow(try record([boundary]))
        let maximumSeconds: Double = 28_800.0
        let excessiveSeconds: Double = maximumSeconds + 0.001
        XCTAssertNoThrow(try record([], seconds: maximumSeconds))
        XCTAssertThrowsError(try record([], seconds: excessiveSeconds))
    }

    func testPreservesOrderedOverlapsButRejectsReversalAndDuplicateIDs() throws {
        let first = try segment("甲", start: 0, end: 5_000, speaker: "speaker-1")
        let overlapping = try segment("乙", start: 1_000, end: 3_000, speaker: "speaker-2")
        let equalStart = try segment("丙", start: 1_000, end: 2_000)
        let expected: [IOConversationSegment] = [first, overlapping, equalStart]
        let ordered = try record(expected)
        XCTAssertEqual(ordered.segments, expected)
        XCTAssertThrowsError(try record([overlapping, first]))
        XCTAssertThrowsError(try record([first, first]))
    }

    func testUnknownOrUnclearGapsAreExplicitAndDoNotInventWords() throws {
        let gap = try segment("", start: 1_000, end: 2_000, unclear: true)
        XCTAssertNil(gap.speakerLabel)
        XCTAssertNil(gap.confidence)
        let gapRecord = try record([gap])
        let gapMatches = try gapRecord.matches(containing: "听不清")
        XCTAssertTrue(gapMatches.isEmpty)
        XCTAssertThrowsError(try segment(""))
        XCTAssertThrowsError(try segment(" \n\t"))
        XCTAssertThrowsError(try segment("", start: 1_000, end: 1_000, unclear: true))
        XCTAssertNoThrow(try segment("可能是这个词", confidence: 0.2, unclear: true))
        XCTAssertThrowsError(try segment("原文\u{0}错误"))
    }

    func testSpeakerLabelsAndConfidenceAreNotUnvalidatedIdentityFields() throws {
        for label in ["张三", "speaker-0", "speaker-01", "speaker-1000", "speaker-١", "speaker-1\n", "", "S1"] {
            XCTAssertThrowsError(try segment(speaker: label), label)
        }
        XCTAssertNoThrow(try segment(speaker: "speaker-1", confidence: 0))
        XCTAssertNoThrow(try segment(speaker: "speaker-999", confidence: 1))
        let invalidConfidence: [Double] = [-0.1, 1.01, Double.nan, Double.infinity]
        for bad in invalidConfidence {
            XCTAssertThrowsError(try segment(confidence: bad))
        }
    }

    func testUTF8ByteBoundsAndConfigurableSegmentLimit() throws {
        let cap: Int = IOConversationBounds.defaultSegmentTextBytes
        let exact = String(repeating: "a", count: cap)
        let excessiveText = exact + "a"
        let excessiveChineseCount: Int = cap / 3 + 1
        let excessiveChineseText = String(repeating: "中", count: excessiveChineseCount)
        let largerLimit: Int = cap + 1
        XCTAssertNoThrow(try segment(exact))
        XCTAssertThrowsError(try segment(excessiveText))
        XCTAssertThrowsError(try segment(excessiveChineseText))
        let larger = try IOConversationSegment(startMilliseconds: 0, endMilliseconds: 1_000,
                                               recognizedText: excessiveText, maximumTextBytes: largerLimit)
        XCTAssertThrowsError(try record([larger]))
        let oneSecondLater = start.addingTimeInterval(1)
        XCTAssertNoThrow(try IOConversationRecord(startedAtUTC: start, endedAtUTC: oneSecondLater,
                                                  segments: [larger], maximumSegmentTextBytes: largerLimit))
        let overTotalLimit: Int = IOConversationBounds.maximumTextBytes + 1
        let invalidLimits: [Int] = [0, -1, overTotalLimit, Int.max]
        for invalid in invalidLimits {
            XCTAssertThrowsError(try IOConversationRecord(startedAtUTC: start, endedAtUTC: start,
                                                           segments: [], maximumSegmentTextBytes: invalid))
        }
    }

    func testTotalTextAndSegmentCountExactLimits() throws {
        let block = String(repeating: "a", count: IOConversationBounds.defaultSegmentTextBytes)
        var full: [IOConversationSegment] = []
        full.reserveCapacity(33)
        for index in 0..<32 {
            let startMilliseconds: Int64 = Int64(index) * 1_000
            let endMilliseconds: Int64 = startMilliseconds + 1_000
            let piece = try segment(block, start: startMilliseconds, end: endMilliseconds)
            full.append(piece)
        }
        XCTAssertNoThrow(try record(full))
        let overflowPiece = try segment("a", start: 32_000, end: 33_000)
        full.append(overflowPiece)
        XCTAssertThrowsError(try record(full))
        var many: [IOConversationSegment] = []
        let maximumSegments: Int = IOConversationBounds.maximumSegments
        many.reserveCapacity(maximumSegments + 1)
        for index in 0..<maximumSegments {
            let startMilliseconds: Int64 = Int64(index)
            let endMilliseconds: Int64 = startMilliseconds + 1
            let piece = try segment("字", start: startMilliseconds, end: endMilliseconds)
            many.append(piece)
        }
        XCTAssertNoThrow(try record(many))
        let overflowCountPiece = try segment("字", start: 10_000, end: 10_001)
        many.append(overflowCountPiece)
        XCTAssertThrowsError(try record(many))
    }

    func testSearchIsBoundedAndCaseInsensitiveWithoutChangingOriginal() throws {
        let piece = try segment("DeepSeek 原文")
        let value = try record([piece])
        let caseInsensitiveHits = try value.matches(containing: "deepseek")
        XCTAssertEqual(caseInsensitiveHits.first?.segment, piece)
        let excessiveQuery = String(repeating: "中", count: 171)
        let invalidQueries: [String] = ["", " \n", excessiveQuery]
        for invalid in invalidQueries {
            XCTAssertThrowsError(try value.matches(containing: invalid))
        }
        let invalidLimits: [Int] = [0, -1, 1_001, Int.max]
        for invalid in invalidLimits {
            XCTAssertThrowsError(try value.matches(containing: "原文", limit: invalid))
        }
    }
}
