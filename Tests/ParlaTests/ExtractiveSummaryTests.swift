import XCTest
@testable import ParlaCore

/// The extractive summary is what EVERY user gets, on every platform, with no download — so its quality is
/// the free tier's quality. These pin three fixes to it: coverage of the whole note instead of its opening,
/// a length that scales with the note, and a summary that says three different things instead of one thing
/// three times.
final class ExtractiveSummaryTests: ParlaTestCase {

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

    /// Mean-centering, pinned so that removing it turns this RED.
    ///
    /// The previous version of this test passed with centering reverted — its fixture was too easy, so it proved
    /// nothing. `NLContextualEmbedding` is anisotropic: every vector carries a large shared direction. The
    /// sentence CLOSEST to that shared direction is the blandest one, and on RAW cosines it looks most similar to
    /// everything, so TextRank crowns it. Centering subtracts the shared direction, and the bland sentence — now
    /// nearly the zero vector — correctly falls to the bottom.
    func testCenteringStopsTheBlandestSentenceFromWinningTheTitle() throws {
        let shared = 10.0
        var vectors: [[Double]] = []
        for _ in 0..<3 { vectors.append([shared + 1, shared, shared]) }   // 0,1,2 — the dominant topic
        for _ in 0..<2 { vectors.append([shared, shared + 1, shared]) }   // 3,4   — a second topic
        let filler = vectors.count
        vectors.append([shared, shared, shared])                          // 5 — pure background, says nothing

        let selection = try XCTUnwrap(SemanticIndex.extractiveSelection(vectors, summaryCount: 1))
        XCTAssertNotEqual(selection.title, filler,
                          "the blandest sentence wins on raw cosines — centering is what stops it")
    }

    /// MMR, pinned so that reverting to top-k centrality turns this RED.
    ///
    /// The previous fixture went red only when BOTH fixes were reverted, so neither was actually pinned. With a
    /// clearly dominant cluster, ranking by centrality alone fills the whole summary from it — which is the
    /// "same thing three times" this change exists to prevent.
    func testSummaryReachesOutsideTheDominantClusterEvenWhenItIsLarge() throws {
        var vectors: [[Double]] = []
        for i in 0..<6 { vectors.append([1, Double(i) * 0.01, 0]) }   // 0...5 — one big, tight topic
        vectors.append([0, 1, 0])                                     // 6 — a different topic
        vectors.append([0, 0.98, 0.1])                                // 7 — near it

        let selection = try XCTUnwrap(SemanticIndex.extractiveSelection(vectors, summaryCount: 3))
        XCTAssertEqual(selection.summary.count, 3)
        XCTAssertTrue(selection.summary.contains { $0 >= 6 },
                      "a 3-sentence summary must not be three sentences from one tight cluster — got \(selection.summary)")
    }
}
