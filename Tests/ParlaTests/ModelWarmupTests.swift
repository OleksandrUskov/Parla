import XCTest
@testable import ParlaCore

/// What the app says while a recognition model is being prepared.
///
/// The wait is real and large: measured on the shipping 626 MB model, **431 s the first time on a device and
/// 10 s every time after**, because Core ML compiles the model for the Neural Engine once and caches the
/// result per app container. Seven motionless minutes under "Loading the model…" is indistinguishable from a
/// hang, and it lands on the first thing a new user — or an App Review tester — ever does.
///
/// Two things are pinned here. That the explanation is asked PER MODEL, which is what both platforms got wrong
/// in opposite directions: macOS showed it once per install and never again, so choosing a different model
/// paid the whole cost with no explanation, while iOS showed it on every single load. And that a model counts
/// as warm only when its load actually FINISHED — a failed or cancelled load has paid nothing.
final class ModelWarmupTests: ParlaTestCase {

    override func tearDown() {
        // The suite writes through to the real defaults, as the others here do. Do not leave a fake model
        // name behind marked as compiled.
        UserDefaults.standard.removeObject(forKey: AppModel.Keys.warmedModels)
        super.tearDown()
    }

    @MainActor private func makeModel() -> AppModel {
        UserDefaults.standard.removeObject(forKey: AppModel.Keys.warmedModels)
        return AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
    }

    // MARK: the clock

    /// Elapsed time, not a percentage — and the difference is the point. WhisperKit reports progress for the
    /// DOWNLOAD only; the initialiser that compiles reports nothing, so any bar would be extrapolated from a
    /// hardcoded duration across hardware spanning an M-series Mac and an iPhone. A bar stuck at 99% is worse
    /// than no bar.
    func testTheClockReadsAsAClock() {
        XCTAssertEqual(ModelWarmup.elapsedLabel(0), "0:00")
        XCTAssertEqual(ModelWarmup.elapsedLabel(7), "0:07")
        XCTAssertEqual(ModelWarmup.elapsedLabel(65), "1:05")
        XCTAssertEqual(ModelWarmup.elapsedLabel(431), "7:11", "the measured first-compile wait")
    }

    /// Past an hour it must not read "83:20", which is not a duration anyone parses.
    func testAnHourGrowsAnHoursField() {
        XCTAssertEqual(ModelWarmup.elapsedLabel(3_600), "1:00:00")
        XCTAssertEqual(ModelWarmup.elapsedLabel(3_725), "1:02:05")
        XCTAssertEqual(ModelWarmup.elapsedLabel(5_000), "1:23:20")
    }

    /// A clock change can hand this a negative interval, and a broken date can hand it a non-number. Neither
    /// may produce a countdown, a crash, or "-1:-3".
    func testNonsenseInputsClampToZero() {
        for bad in [-1, -10_000, TimeInterval.infinity, -TimeInterval.infinity, TimeInterval.nan] {
            XCTAssertEqual(ModelWarmup.elapsedLabel(bad), "0:00", "\(bad)")
        }
    }

    /// A warm load is about ten seconds; a timer flickering "0:02" on it is noise. The clock exists for the
    /// cold load, so it appears only once the wait is long enough to be worth counting.
    func testTheClockStaysOutOfTheWayOnAQuickLoad() {
        XCTAssertFalse(ModelWarmup.shouldShowElapsed(0))
        XCTAssertFalse(ModelWarmup.shouldShowElapsed(4.9))
        XCTAssertTrue(ModelWarmup.shouldShowElapsed(5))
        XCTAssertTrue(ModelWarmup.shouldShowElapsed(431))
        XCTAssertFalse(ModelWarmup.shouldShowElapsed(.nan))
    }

    // MARK: warmth is per model

    /// 🔴 The correction. A different model having compiled says NOTHING about this one — it pays the whole
    /// cost again — and that is exactly what a single global flag could not express.
    func testWarmthIsAskedAboutTheModelNotTheInstall() {
        XCTAssertTrue(ModelWarmup.shouldExplainWait(for: "large-v3", warmed: []))
        XCTAssertFalse(ModelWarmup.shouldExplainWait(for: "large-v3", warmed: ["large-v3"]))
        XCTAssertTrue(ModelWarmup.shouldExplainWait(for: "large-v3", warmed: ["tiny", "base"]),
                      "another model being compiled says nothing about this one")
        XCTAssertFalse(ModelWarmup.shouldExplainWait(for: "", warmed: []), "nothing is loading — say nothing")
    }

    /// Upgrading an install that only ever had the global boolean. Someone whose flag was already true has one
    /// warm model — the one they were using — and must not be told "this happens once" about a load that is
    /// now fast. Nothing is claimed about any other model, which is the improvement.
    func testTheOldGlobalFlagMigratesToTheModelItWasAbout() {
        XCTAssertEqual(ModelWarmup.migratedWarmSet(legacyDidCompile: true, currentModel: "large-v3"), ["large-v3"])
        XCTAssertEqual(ModelWarmup.migratedWarmSet(legacyDidCompile: false, currentModel: "large-v3"), [])
        XCTAssertEqual(ModelWarmup.migratedWarmSet(legacyDidCompile: true, currentModel: ""), [])
    }

    // MARK: when a model actually becomes warm

    /// The load FINISHING is the signal, and the only one available — nothing reports the compile itself.
    @MainActor func testAModelIsWarmOnceRealWorkStarts() {
        let m = makeModel()
        m.phase = .loadingModel("tiny")
        XCTAssertTrue(m.isPreparingColdModel, "never compiled here → explain the wait")

        m.phase = .transcribing("note.m4a")
        XCTAssertTrue(m.warmedModels.contains("tiny"))

        m.phase = .loadingModel("tiny")
        XCTAssertFalse(m.isPreparingColdModel, "second load of the same model is seconds — say nothing")
    }

    /// 🔴 A load that failed or was cancelled has paid NOTHING, so the next attempt must still explain itself.
    /// Marking on any exit from `.loadingModel` would silence the explanation for a model still uncompiled.
    @MainActor func testAFailedOrCancelledLoadDoesNotCountAsCompiled() {
        for ending in [EnginePhase.failed("out of memory"), .idle] {
            let m = makeModel()
            m.phase = .loadingModel("large-v3")
            m.phase = ending
            XCTAssertFalse(m.warmedModels.contains("large-v3"), "\(ending) did not compile anything")
        }
    }

    /// Switching models mid-life: the first stays warm, the second is cold until it too finishes.
    @MainActor func testWarmthAccumulatesPerModel() {
        let m = makeModel()
        m.phase = .loadingModel("tiny");  m.phase = .transcribing("a.m4a")
        m.phase = .loadingModel("large-v3")
        XCTAssertTrue(m.isPreparingColdModel, "a newly chosen model pays the whole compile again")
        m.phase = .transcribing("b.m4a")
        XCTAssertEqual(m.warmedModels, ["tiny", "large-v3"])
    }

    // MARK: the clock's lifetime

    @MainActor func testTheClockRunsOnlyWhileAModelIsLoading() {
        let m = makeModel()
        XCTAssertNil(m.modelLoadStartedAt, "nothing is loading")

        m.phase = .loadingModel("tiny")
        let started = m.modelLoadStartedAt
        XCTAssertNotNil(started)

        // WhisperKit reports `.loading` more than once; a repeat must not restart the clock, or a long wait
        // would keep resetting to 0:00 and read as though nothing were happening.
        m.phase = .loadingModel("tiny")
        XCTAssertEqual(m.modelLoadStartedAt, started, "a repeated load event must not restart the clock")

        m.phase = .transcribing("a.m4a")
        XCTAssertNil(m.modelLoadStartedAt, "the load is over — stop counting")
    }
}
