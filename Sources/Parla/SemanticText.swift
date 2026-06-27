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
    "ещё", "еще", "где", "уже", "просто", "очень", "куча", "более", "менее", "каждый",
    // uk
    "це", "цей", "той", "якщо", "коли", "потім", "зараз", "взагалі", "який", "щоб", "діло", "річ", "раз",
    // en
    "this", "that", "these", "those", "thing", "stuff", "kind", "lot", "way", "okay", "yeah", "bit",
]

/// RU + UK vowels — for the verb-infinitive discriminator below.
private let cyrillicVowels: Set<Character> = ["а", "е", "ё", "и", "о", "у", "ы", "э", "ю", "я", "і", "ї", "є"]
/// Real nouns ending in vowel+ь that the verb rule would otherwise mistake for infinitives.
private let softSignNouns: Set<String> = ["сеть", "путь"]

/// True if a lemma is a RU/UK verb infinitive (not a noun). Verb infinitives end in vowel+ть, or
/// -ться/-тися/-чь/-ти; feminine soft-sign nouns end in consonant+ть («часть», «власть») and are kept.
/// (NLTagger's `.lexicalClass` mislabels conjugated Russian verbs as nouns, but `.lemma` is reliable —
/// it returns the infinitive — so this suffix rule is the deterministic discriminator. Validated by research.)
func looksLikeVerbLemma(_ lemma: String) -> Bool {
    let w = lemma.lowercased()
    guard w.count > 3, !softSignNouns.contains(w) else { return false }
    if w.hasSuffix("ться") || w.hasSuffix("тися") || w.hasSuffix("чь") || w.hasSuffix("ти") { return true }
    if w.hasSuffix("ть") {
        let beforeТь = w[w.index(w.endIndex, offsetBy: -3)]   // the char just before "ть"
        return cyrillicVowels.contains(beforeТь)
    }
    return false
}

/// True if a lemma is a RU/UK adjective/participle by its ending. The len≥5 guard protects short nouns.
func looksLikeAdjectiveLemma(_ lemma: String) -> Bool {
    let w = lemma.lowercased()
    guard w.count >= 5 else { return false }
    let adjective = ["ый", "ий", "ой", "ая", "яя", "ое", "ее", "ого", "его", "ому", "ему", "ых", "их", "ыми", "ими"]
    let participle = ["ущий", "ющий", "ащий", "ящий", "вший", "нный", "емый", "имый", "тый"]
    return adjective.contains(where: w.hasSuffix) || participle.contains(where: w.hasSuffix)
}

/// Lexical classes that are NEVER keywords — hard-rejected up front. We do NOT positively gate on `.noun`
/// because NLTagger mislabels real nouns (сеть/портфель/спринт) as adjective/adverb; the lemma morphology
/// filter (above) does the precise verb/adjective removal instead.
private let rejectedClasses: Set<NLTag> = [.verb, .particle, .conjunction, .preposition, .interjection, .determiner]

/// Candidate keyword terms for embedding-ranking: lemmatized, morphology-filtered, deduped,
/// frequency-ordered, up to `max`. Lexical only (NLTagger, no assets) — just the CANDIDATE pool; the
/// on-topic winners are then picked by cosine to the document vector (KeyBERT-style) in
/// `AppModel.rankedKeywords`. Passing `language` improves tagging; the lemma merges inflections
/// («биржу»/«бирж» → «биржа»). Verbs/adjectives are dropped by morphology, not by the unreliable POS tag.
func keywordCandidates(from text: String, language: String = "", max: Int = 16) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let range = trimmed.startIndex..<trimmed.endIndex
    let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
    tagger.string = trimmed
    let subtag = languagePrimarySubtag(language)
    if !subtag.isEmpty { tagger.setLanguage(NLLanguage(subtag), range: range) }
    var terms: [String] = []
    let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther]
    tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: options) { tag, tokenRange in
        if let tag, rejectedClasses.contains(tag) { return true }   // clear non-noun → skip
        let lemma = tagger.tag(at: tokenRange.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
        let word = (lemma?.isEmpty == false) ? lemma! : String(trimmed[tokenRange])
        let key = word.lowercased()
        guard key.count > 2, !keywordStopwords.contains(key),
              !looksLikeVerbLemma(word), !looksLikeAdjectiveLemma(word) else { return true }
        terms.append(word)
        return true
    }
    return topTerms(terms, max: max)
}
