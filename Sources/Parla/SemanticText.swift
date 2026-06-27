import Foundation
import NaturalLanguage

// MARK: - Text utilities for the Local-AI Layer (P1d) — sentence split + keyword phrase
//
// NaturalLanguage tokenizers/taggers — on-device, deterministic, NO asset download (unlike the
// contextual-embedding model). The output QUALITY varies by language (best for RU/EN; UK is thinner),
// so the keyword-phrase title is user-evaluated live against the central-sentence style.

/// Split text into sentences (NLTokenizer). Empty/blank → []. Each sentence trimmed; blanks dropped.
func sentences(in text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = trimmed
    var out: [String] = []
    tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
        let s = trimmed[range].trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { out.append(s) }
        return true
    }
    return out
}

/// A short keyword-phrase title: the most frequent content words (nouns), top `max`, joined. Lexical
/// only (NLTagger) — no embeddings, no assets. "" when nothing salient (the caller falls back to the
/// sentence title / sourceName). The "keyword-phrase" title style.
func keywordPhrase(from text: String, max: Int = 3, separator: String = " · ") -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let tagger = NLTagger(tagSchemes: [.lexicalClass])
    tagger.string = trimmed
    var nouns: [String] = []
    let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther]
    tagger.enumerateTags(in: trimmed.startIndex..<trimmed.endIndex, unit: .word,
                         scheme: .lexicalClass, options: options) { tag, range in
        if tag == .noun {
            let word = String(trimmed[range])
            if word.count > 2 { nouns.append(word) }   // drop 1-2 char noise
        }
        return true
    }
    return topTerms(nouns, max: max).joined(separator: separator)
}
