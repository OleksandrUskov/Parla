import XCTest
@testable import ParlaCore

/// WhisperKit resolves its tokenizer through `config.tokenizerFolder ?? config.downloadBase`. A config that
/// passes NEITHER falls back to HubApi's default — the old `~/Documents/huggingface`.
///
/// That was survivable only while the models lived there too. The relocation moved them, including the `openai`
/// repos that hold the tokenizer, so a bare config would have looked for it where nothing remains: offline, a
/// fully downloaded model stops transcribing; online, it silently re-downloads into Documents and undoes the
/// relocation. Verified on the development machine before the fix — the only tokenizer.json files were under
/// `openai/`, and the `argmaxinc` model folders had none.
///
/// This is a claim about how the engine is CONFIGURED, which no runtime assertion can reach without a real
/// 626 MB model, so it is checked in the source — and checked structurally rather than by substring, because a
/// substring scan passes on a commented-out line, which is a lesson this project learned the same day.
final class TokenizerLocationTests: ParlaLogicTestCase {

    func testEveryWhisperKitConfigPassesTheDownloadBase() throws {
        let file = repoRoot.appendingPathComponent("Sources/ParlaCore/TranscriptionEngine.swift")
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var configs = 0
        for (i, line) in lines.enumerated() {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//"), !code.hasPrefix("///"), code.contains("WhisperKitConfig(") else { continue }
            configs += 1
            // The call may wrap; the base must appear within the argument list, which never runs past a few lines.
            let window = lines[i...min(i + 3, lines.count - 1)].joined(separator: " ")
            XCTAssertTrue(window.contains("downloadBase:"),
                          "line \(i + 1) builds a WhisperKitConfig without downloadBase — WhisperKit would look "
                          + "for the tokenizer in the user's Documents, where the relocation no longer keeps it")
        }
        XCTAssertGreaterThanOrEqual(configs, 2, "the scan found no configs — the file moved and this test is blind")
    }

    /// …and the place it points to is the same tree the models are relocated into, not a sibling of it.
    func testTheTokenizerIsLookedForWhereTheModelsWereMovedTo() {
        let base = TranscriptionEngine.downloadBase()
        XCTAssertEqual(TranscriptionEngine.modelsRoot().deletingLastPathComponent().deletingLastPathComponent(),
                       base.appendingPathComponent("models", isDirectory: true),
                       "models and tokenizers must share one base, or one of them is orphaned")
        XCTAssertTrue(TranscriptionEngine.hubRepoOwners.contains("openai"),
                      "the tokenizer repos must be relocated with the models — leaving them behind strands them "
                      + "in Documents, which is the location this whole change exists to empty")
    }
}
