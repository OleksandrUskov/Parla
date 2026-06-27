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

/// Function words / fillers the POS tagger sometimes mislabels as nouns in casual speech — never useful
/// as keywords. Matched (lowercased) against the lemma. Small on purpose; real nouns rarely collide.
private let keywordStopwords: Set<String> = [
    // ru
    "это", "этот", "тот", "весь", "если", "когда", "потом", "сейчас", "вообще", "короче", "типа",
    "вот", "там", "тут", "так", "такой", "свой", "наш", "ваш", "который", "чтобы", "дело", "вещь", "раз",
    // uk
    "це", "цей", "той", "якщо", "коли", "потім", "зараз", "взагалі", "який", "щоб", "діло", "річ", "раз",
    // en
    "this", "that", "these", "those", "thing", "stuff", "kind", "lot", "way", "okay", "yeah", "bit",
]

/// Keyword tags: the most frequent content nouns, lemmatized, top `max`, best first. Lexical only
/// (NLTagger) — no embeddings, no assets. Passing `language` fixes POS tagging on casual speech (so
/// adverbs/verbs/conjunctions aren't mistaken for nouns), and the lemma merges inflections
/// («биржу»/«бирж» → «биржа») so a repeated topic actually wins on frequency. [] when nothing salient.
func keywordList(from text: String, language: String = "", max: Int = 4) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let range = trimmed.startIndex..<trimmed.endIndex
    let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
    tagger.string = trimmed
    let subtag = languagePrimarySubtag(language)
    if !subtag.isEmpty { tagger.setLanguage(NLLanguage(subtag), range: range) }
    var nouns: [String] = []
    let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther]
    tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: options) { tag, tokenRange in
        guard tag == .noun else { return true }
        let lemma = tagger.tag(at: tokenRange.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
        let word = (lemma?.isEmpty == false) ? lemma! : String(trimmed[tokenRange])
        let key = word.lowercased()
        if key.count > 2, !keywordStopwords.contains(key) { nouns.append(word) }
        return true
    }
    return topTerms(nouns, max: max)
}
