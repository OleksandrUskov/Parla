import Foundation
import NaturalLanguage

// MARK: - Text utilities for the Local-AI Layer (P1d) — sentence split + keyword phrase
//
// NaturalLanguage tokenizers/taggers — on-device, deterministic, NO asset download (unlike the
// contextual-embedding model). The output QUALITY varies by language (best for RU/EN; UK is thinner),
// so the keyword-phrase title is user-evaluated live against the central-sentence style.

/// Dominant writing script of a string: "cyrillic" (RU/UK/…) vs "latin" (EN/…) vs "other". Counts letters
/// directly — far more reliable on SHORT search queries than NLLanguageRecognizer (which mislabels e.g.
/// "проект"→Bulgarian). NLContextualEmbedding is script-based, so this is what actually decides which model
/// (and thus which vector space) a query is embedded in — RU and UK both map to the Cyrillic space.
public func dominantScript(_ text: String) -> String {
    var cyrillic = 0, latin = 0
    for scalar in text.unicodeScalars {
        if (0x0400...0x04FF).contains(scalar.value) { cyrillic += 1 }
        else if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) { latin += 1 }
    }
    if cyrillic == 0 && latin == 0 { return "other" }
    return cyrillic >= latin ? "cyrillic" : "latin"
}

/// Split text into sentences (NLTokenizer). Empty/blank → []. Each sentence trimmed; blanks dropped.
public func sentences(in text: String) -> [String] {
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

/// Lemmas for morphology-aware SEARCH, routed by SCRIPT so the index and the query apply the IDENTICAL
/// transform and can never disagree. This symmetry is the whole point: `lemmaSet` is run on BOTH sides
/// (note text when indexing, query when searching) through THIS function, so whatever lemma a word gets,
/// both sides get the same one — linguistic correctness matters less than agreement. (Routing the index by
/// the note's stored language but the query by script silently breaks UK/DE/FR: e.g. a UK note indexed as
/// "uk" vs a query forced to "ru" would never match — the round-2 review caught exactly this.) Cyrillic→ru,
/// Latin→en, else unset. RU/UK can't be told apart from a short query, so both ride the "ru" lemmatizer.
public func searchLemmaSet(of text: String) -> Set<String> {
    // Lemmatize ONLY Cyrillic (RU/UK — Parla's languages). Latin/other fall back to substring search: NLTagger's
    // EN lemma is inconsistent (verified — «meeting»→«meet» conflates the verb, while «meeting»/«meetings» split
    // to different lemmas), producing wrong/missed matches not worth it for a secondary language. UK has no
    // on-device lemma model, so RU-routing reduces it only partially (робота/роботу→робот, but not роботі) — a
    // best-effort tool limit; a real multilingual lemmatizer is a P3 download-tier option. (LOCAL_AI_LAYER.md §5b)
    guard dominantScript(text) == "cyrillic" else { return [] }
    return lemmaSet(of: text, language: "ru")
}

/// NLTagger lemma corrections for irregular words whose output isn't self-consistent across cases — so the
/// nominative and oblique forms collapse to ONE lemma and actually match. Verified misses: «деньги» (pluralia
/// tantum) → obliques «деньга» but nom stays «деньги»; «мать»/«дочь» → obliques «матерь»/«дочерь» but nom stays
/// «мать»/«дочь». A small CLOSED exceptions table (standard NLP practice — unlike the open-class stopword list);
/// extend only as real, verified misses surface. (время/имя/путь/люди/дети are self-consistent — no entry needed.)
public let lemmaOverrides: [String: String] = ["деньги": "деньга", "матерь": "мать", "дочерь": "дочь"]

/// Lemmatized content tokens of `text` as a lowercased set — the morphology primitive behind `searchLemmaSet`.
/// «работа» reduces to the same lemma as «работе»/«работу», so a base-form query finds inflected notes. Uses
/// NLTagger `.lemma` (no asset download), falling back to the surface form when no lemma; tokens ≤2 chars
/// dropped as noise. Pure — `AppModel` caches the per-item result (lemmatizing the corpus on every keystroke
/// would be wasteful). NLTagger's RU lemmatizer isn't self-consistent for a few irregulars (nom ≠ oblique lemma);
/// those are corrected via the closed `lemmaOverrides` table applied below (e.g. «деньги»→«деньга»,
/// «матерь»→«мать») so all forms collapse and match. NOT semantic search: matches word FORMS literally present,
/// not meaning (that's the download-tier; LOCAL_AI_LAYER.md §5).
public func lemmaSet(of text: String, language: String = "") -> Set<String> {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let range = trimmed.startIndex..<trimmed.endIndex
    let tagger = NLTagger(tagSchemes: [.lemma])
    tagger.string = trimmed
    let subtag = languagePrimarySubtag(language)
    if !subtag.isEmpty { tagger.setLanguage(NLLanguage(subtag), range: range) }
    var out: Set<String> = []
    let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther]
    tagger.enumerateTags(in: range, unit: .word, scheme: .lemma, options: options) { tag, tokenRange in
        let lemma = tag?.rawValue
        let word = (lemma?.isEmpty == false) ? lemma! : String(trimmed[tokenRange])
        let key = word.lowercased()
        if key.count > 2 { out.insert(lemmaOverrides[key] ?? key) }   // correct known irregulars (e.g. деньги→деньга)
        return true
    }
    return out
}

// `keywordStopwords` (the curated RU/UK/EN function-word set) lives in `Stopwords.swift`.

/// RU + UK vowels — for the verb-infinitive discriminator below.
private let cyrillicVowels: Set<Character> = ["а", "е", "ё", "и", "о", "у", "ы", "э", "ю", "я", "і", "ї", "є"]
/// Real nouns ending in vowel+ь that the verb rule would otherwise mistake for infinitives.
private let softSignNouns: Set<String> = ["сеть", "путь"]

/// True if a lemma is a RU/UK verb infinitive (not a noun). Verb infinitives end in vowel+ть, or
/// -ться/-тися/-чь/-ти; feminine soft-sign nouns end in consonant+ть («часть», «власть») and are kept.
/// (NLTagger's `.lexicalClass` mislabels conjugated Russian verbs as nouns, but `.lemma` is reliable —
/// it returns the infinitive — so this suffix rule is the deterministic discriminator. Validated by research.)
public func looksLikeVerbLemma(_ lemma: String) -> Bool {
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
public func looksLikeAdjectiveLemma(_ lemma: String) -> Bool {
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

/// Candidate keyword terms with the document ranges where each occurs — lemmatized, morphology-filtered,
/// deduped, frequency-ordered, up to `max`. Lexical only (NLTagger, no assets) — just the CANDIDATE pool;
/// the on-topic winners are picked by cosine to the document vector (KeyBERT-style) in
/// `AppModel.rankedKeywords`, which pools each candidate's IN-CONTEXT token vectors using these ranges.
/// **Ranges index `text` as given** (caller passes the same clean string it embeds). Verbs/adjectives are
/// dropped by morphology, not the unreliable POS tag; the lemma merges inflections («биржу»/«бирж» → «биржа»).
public func keywordCandidatesWithRanges(from text: String, language: String = "", max: Int = 16)
    -> [(term: String, ranges: [Range<String.Index>])] {
    guard !text.isEmpty else { return [] }
    let range = text.startIndex..<text.endIndex
    let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
    tagger.string = text
    let subtag = languagePrimarySubtag(language)
    if !subtag.isEmpty { tagger.setLanguage(NLLanguage(subtag), range: range) }
    var display: [String: String] = [:]              // key → first-seen display form
    var ranges: [String: [Range<String.Index>]] = [:]
    var freq: [String: Int] = [:]
    var order: [String] = []
    let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther]
    tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: options) { tag, tokenRange in
        if let tag, rejectedClasses.contains(tag) { return true }   // clear non-noun → skip
        let lemma = tagger.tag(at: tokenRange.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
        let word = (lemma?.isEmpty == false) ? lemma! : String(text[tokenRange])
        let key = word.lowercased()
        guard key.count > 2, !keywordStopwords.contains(key),
              !looksLikeVerbLemma(word), !looksLikeAdjectiveLemma(word) else { return true }
        if freq[key] == nil { display[key] = word; order.append(key) }
        freq[key, default: 0] += 1
        ranges[key, default: []].append(tokenRange)
        return true
    }
    let ranked = order.enumerated().sorted { a, b in
        freq[a.element]! != freq[b.element]! ? freq[a.element]! > freq[b.element]! : a.offset < b.offset
    }
    return ranked.prefix(max).map { (term: display[$0.element]!, ranges: ranges[$0.element]!) }
}

/// Convenience: candidate terms only (no ranges). Used where context-pooling isn't needed.
public func keywordCandidates(from text: String, language: String = "", max: Int = 16) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return keywordCandidatesWithRanges(from: trimmed, language: language, max: max).map(\.term)
}
