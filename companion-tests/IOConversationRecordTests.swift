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
        XCTAssertEqual(hits.map(\.segment.id), [first.id, second.id])
        XCTAssertEqual(Data(hits[0].segment.recognizedText.utf8), Data(original.utf8))
        XCTAssertEqual(hits[0].sessionID, value.id)
        XCTAssertEqual(hits[0].startUTC, start.addingTimeInterval(1.25))
        XCTAssertEqual(hits[0].endUTC, start.addingTimeInterval(3.75))
        XCTAssertEqual(try value.matches(containing: "眼镜", limit: 1).count, 1)
        XCTAssertTrue(try value.matches(containing: "不存在").isEmpty)
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
        XCTAssertEqual(try a.matches(containing: "原文"), try b.matches(containing: "原文"))
    }

    func testRejectsInvalidSessionAndSegmentTimes() throws {
        XCTAssertThrowsError(try record([], seconds: -1))
        for bad in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try IOConversationRecord(startedAtUTC: Date(timeIntervalSince1970: bad),
                                                           endedAtUTC: start, segments: []))
            XCTAssertThrowsError(try IOConversationRecord(startedAtUTC: start,
                                                           endedAtUTC: Date(timeIntervalSince1970: bad), segments: []))
        }
        XCTAssertThrowsError(try segment(start: -1))
        XCTAssertThrowsError(try segment(start: 2_000, end: 1_000))
        XCTAssertThrowsError(try segment(end: Int64.max))
        XCTAssertThrowsError(try record([segment(end: 60_001)]))
        XCTAssertNoThrow(try record([segment(end: 60_000)]))
        XCTAssertNoThrow(try record([], seconds: 8 * 60 * 60))
        XCTAssertThrowsError(try record([], seconds: 8 * 60 * 60 + 0.001))
    }

    func testPreservesOrderedOverlapsButRejectsReversalAndDuplicateIDs() throws {
        let first = try segment("甲", start: 0, end: 5_000, speaker: "speaker-1")
        let overlapping = try segment("乙", start: 1_000, end: 3_000, speaker: "speaker-2")
        let equalStart = try segment("丙", start: 1_000, end: 2_000)
        XCTAssertEqual(try record([first, overlapping, equalStart]).segments, [first, overlapping, equalStart])
        XCTAssertThrowsError(try record([overlapping, first]))
        XCTAssertThrowsError(try record([first, first]))
    }

    func testUnknownOrUnclearGapsAreExplicitAndDoNotInventWords() throws {
        let gap = try segment("", start: 1_000, end: 2_000, unclear: true)
        XCTAssertNil(gap.speakerLabel)
        XCTAssertNil(gap.confidence)
        XCTAssertTrue(try record([gap]).matches(containing: "听不清").isEmpty)
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
        for bad in [-0.1, 1.01, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try segment(confidence: bad))
        }
    }

    func testUTF8ByteBoundsAndConfigurableSegmentLimit() throws {
        let cap = IOConversationBounds.defaultSegmentTextBytes
        let exact = String(repeating: "a", count: cap)
        XCTAssertNoThrow(try segment(exact))
        XCTAssertThrowsError(try segment(exact + "a"))
        XCTAssertThrowsError(try segment(String(repeating: "中", count: cap / 3 + 1)))
        let larger = try IOConversationSegment(startMilliseconds: 0, endMilliseconds: 1_000,
                                               recognizedText: exact + "a", maximumTextBytes: cap + 1)
        XCTAssertThrowsError(try record([larger]))
        XCTAssertNoThrow(try IOConversationRecord(startedAtUTC: start, endedAtUTC: start.addingTimeInterval(1),
                                                  segments: [larger], maximumSegmentTextBytes: cap + 1))
        for invalid in [0, -1, IOConversationBounds.maximumTextBytes + 1, Int.max] {
            XCTAssertThrowsError(try IOConversationRecord(startedAtUTC: start, endedAtUTC: start,
                                                           segments: [], maximumSegmentTextBytes: invalid))
        }
    }

    func testTotalTextAndSegmentCountExactLimits() throws {
        let block = String(repeating: "a", count: IOConversationBounds.defaultSegmentTextBytes)
        var full = try (0..<32).map { index in
            try segment(block, start: Int64(index * 1_000), end: Int64((index + 1) * 1_000))
        }
        XCTAssertNoThrow(try record(full))
        full.append(try segment("a", start: 32_000, end: 33_000))
        XCTAssertThrowsError(try record(full))
        var many = try (0..<IOConversationBounds.maximumSegments).map { index in
            try segment("字", start: Int64(index), end: Int64(index + 1))
        }
        XCTAssertNoThrow(try record(many))
        many.append(try segment("字", start: 10_000, end: 10_001))
        XCTAssertThrowsError(try record(many))
    }

    func testSearchIsBoundedAndCaseInsensitiveWithoutChangingOriginal() throws {
        let piece = try segment("DeepSeek 原文")
        let value = try record([piece])
        XCTAssertEqual(try value.matches(containing: "deepseek").first?.segment, piece)
        for invalid in ["", " \n", String(repeating: "中", count: 171)] {
            XCTAssertThrowsError(try value.matches(containing: invalid))
        }
        for invalid in [0, -1, 1_001, Int.max] {
            XCTAssertThrowsError(try value.matches(containing: "原文", limit: invalid))
        }
    }
}
