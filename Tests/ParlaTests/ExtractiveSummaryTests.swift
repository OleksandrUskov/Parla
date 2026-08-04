import XCTest
@testable import ParlaCore

/// The extractive summary is what EVERY user gets, on every platform, with no download — so its quality is
/// the free tier's quality. These pin three fixes to it: coverage of the whole note instead of its opening,
/// a length that scales with the note, and a summary that says three different things instead of one thing
/// three times.
final class ExtractiveSummaryTests: XCTestCase {

    // MARK: spanningSample — coverage of the WHOLE note

    func testSpanningSampleReturnsEverythingWhenItAlreadyFits() {
        XCTAssertEqual(SemanticIndex.spanningSample([1, 2, 3], limit: 10), [1, 2, 3])
        XCTAssertEqual(SemanticIndex.spanningSample([1, 2, 3], limit: 3), [1, 2, 3])
        XCTAssertEqual(SemanticIndex.spanningSample([Int](), limit: 5), [])
    }

    /// THE regression: the cap used to be `prefix(120)`, so a long recording was summarized from its opening
    /// and its ending was invisible. The sample must reach the last sentence.
    func testSpanningSampleKeepsBothEndsAndSpreadsTheMiddle() {
        let items = Array(0..<400)
        let sample = SemanticIndex.spanningSample(items, limit: 120)

        XCTAssertEqual(sample.first, 0, "must keep the opening")
        XCTAssertEqual(sample.last, 399, "must reach the END of the note — this is the whole point")
        XCTAssertLessThanOrEqual(sample.count, 120, "must respect the cap")
        XCTAssertEqual(sample, sample.sorted(), "must stay in document order")
        XCTAssertEqual(Set(sample).count, sample.count, "no duplicates")
        // Real spread, not a lead-heavy clump: the second half of the note must be represented too.
        XCTAssertGreaterThan(sample.filter { $0 >= 200 }.count, 40, "the back half must be sampled, not skipped")
    }

    func testSpanningSampleDegenerateLimits() {
        XCTAssertEqual(SemanticIndex.spanningSample([1, 2, 3], limit: 1), [1])
        XCTAssertEqual(SemanticIndex.spanningSample([1, 2, 3], limit: 0), [])
    }

    // MARK: adaptiveSummaryCount — length that scales with the note

    func testSummaryLengthGrowsWithTheNoteAndStaysBounded() {
        XCTAssertEqual(SemanticIndex.adaptiveSummaryCount(sentenceCount: 0), 0)
        XCTAssertEqual(SemanticIndex.adaptiveSummaryCount(sentenceCount: 1), 1, "never more than we have")
        XCTAssertEqual(SemanticIndex.adaptiveSummaryCount(sentenceCount: 5), 2, "a short note stays short")
        XCTAssertEqual(SemanticIndex.adaptiveSummaryCount(sentenceCount: 25), 5)
        XCTAssertEqual(SemanticIndex.adaptiveSummaryCount(sentenceCount: 400), 7, "a long note never becomes a second transcript")

        // Monotone: a longer note is never summarized more briefly than a shorter one.
        let counts = [1, 4, 9, 16, 36, 100, 400].map { SemanticIndex.adaptiveSummaryCount(sentenceCount: $0) }
        XCTAssertEqual(counts, counts.sorted(), "summary length must not shrink as the note grows")
    }

    // MARK: extractiveSelection — a summary that covers, instead of repeating

    /// Three near-identical sentences (the biggest cluster), two of another topic, one outlier. Ranking purely
    /// by centrality picks the three near-identical ones — a summary that says the same thing three times.
    /// The selection must reach outside the dominant cluster.
    func testSummaryCoversMoreThanTheDominantCluster() throws {
        let clusterA: [[Double]] = [[1, 0, 0], [0.98, 0.12, 0], [0.97, 0.17, 0]]      // indices 0,1,2
        let clusterB: [[Double]] = [[0, 1, 0], [0.10, 0.99, 0]]                       // indices 3,4
        let outlier: [[Double]] = [[0, 0, 1]]                                         // index 5
        let vectors = clusterA + clusterB + outlier

        let selection = try XCTUnwrap(SemanticIndex.extractiveSelection(vectors, summaryCount: 3))
        XCTAssertEqual(selection.summary.count, 3)
        XCTAssertEqual(selection.summary, selection.summary.sorted(), "summary must be in document order")

        let fromA = selection.summary.filter { $0 <= 2 }.count
        XCTAssertLessThan(fromA, 3, "a summary must not be three restatements of the same point")
    }

    func testSelectionHandlesDegenerateInput() {
        XCTAssertNil(SemanticIndex.extractiveSelection([], summaryCount: 3))
        let single = SemanticIndex.extractiveSelection([[1, 0]], summaryCount: 3)
        XCTAssertEqual(single?.title, 0)
        XCTAssertEqual(single?.summary, [0])
    }

    /// `summaryCount: 0` hands the length decision to the note itself — the path production now uses.
    func testSummaryCountZeroMeansAdaptive() throws {
        let vectors: [[Double]] = (0..<25).map { i in [Double(i % 5), Double(i % 3), 1] }
        let selection = try XCTUnwrap(SemanticIndex.extractiveSelection(vectors, summaryCount: 0))
        XCTAssertEqual(selection.summary.count, SemanticIndex.adaptiveSummaryCount(sentenceCount: 25))
    }

    /// Mean-centering is what makes the ranking discriminate at all: `NLContextualEmbedding` vectors are
    /// anisotropic, so every raw pairwise cosine crowds together. Simulated here with a large shared
    /// background direction — without centering the topical signal is swamped and the title is arbitrary.
    func testCenteringRecoversTheSignalUnderAStrongSharedDirection() throws {
        let background = 12.0
        // One sentence sits with the majority topic; the last is off on its own. With a huge shared component
        // every raw cosine is ~1.0, so ranking can only work if the shared direction is removed first.
        var vectors: [[Double]] = (0..<6).map { _ in [background + 1, background, background] }
        vectors.append([background, background, background + 1])   // the outlier

        let selection = try XCTUnwrap(SemanticIndex.extractiveSelection(vectors, summaryCount: 1))
        XCTAssertNotEqual(selection.title, vectors.count - 1,
                          "the title must come from the note's dominant topic, not the lone outlier")
    }
}
