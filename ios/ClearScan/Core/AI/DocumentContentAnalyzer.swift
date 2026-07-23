import Foundation

public enum DocumentCategory: String, CaseIterable, Equatable, Sendable {
  case receipt
  case invoice
  case contract
  case identity
  case academic
  case meetingNotes
  case form
  case letter
  case general

  public var title: String {
    switch self {
    case .receipt: "영수증"
    case .invoice: "청구서"
    case .contract: "계약서"
    case .identity: "신분증"
    case .academic: "학습 자료"
    case .meetingNotes: "회의록"
    case .form: "서식"
    case .letter: "문서"
    case .general: "일반 문서"
    }
  }
}

public struct DocumentContentSuggestion: Equatable, Sendable {
  public let suggestedTitle: String
  public let category: DocumentCategory
  public let confidence: Double
  public let matchedKeywords: [String]

  public init(
    suggestedTitle: String,
    category: DocumentCategory,
    confidence: Double,
    matchedKeywords: [String]
  ) {
    self.suggestedTitle = suggestedTitle
    self.category = category
    self.confidence = confidence
    self.matchedKeywords = matchedKeywords
  }
}

/// Deterministic Korean/English title and category suggestions from text that
/// has already been recognized on-device. No document text is transmitted.
public final class DocumentContentAnalyzer: Sendable {
  public init() {}

  public func analyze(text: String) -> DocumentContentSuggestion {
    let normalizedText = text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
    let matches = Self.rules.map { rule -> RuleMatch in
      let matched = rule.keywords.filter { normalizedText.contains($0.term) }
      return RuleMatch(
        category: rule.category,
        score: matched.reduce(0) { partial, keyword in partial + keyword.weight },
        keywords: matched.map(\.term)
      )
    }
    let ranked = matches.sorted { lhs, rhs in
      if lhs.score == rhs.score {
        return Self.categoryOrder(lhs.category) < Self.categoryOrder(rhs.category)
      }
      return lhs.score > rhs.score
    }
    let best = ranked.first
    let category = (best?.score ?? 0) >= 2 ? best?.category ?? .general : .general
    let bestScore = best?.score ?? 0
    let runnerUpScore = ranked.dropFirst().first?.score ?? 0
    let confidence: Double
    if category == .general {
      confidence = bestScore == 0 ? 0.2 : 0.35
    } else {
      let evidence = Double(bestScore) / Double(bestScore + 3)
      let margin = Double(max(bestScore - runnerUpScore, 0)) / Double(max(bestScore, 1))
      confidence = min(max(0.45 + 0.35 * evidence + 0.20 * margin, 0.45), 0.96)
    }

    return DocumentContentSuggestion(
      suggestedTitle: Self.suggestedTitle(from: text, fallback: category.title),
      category: category,
      confidence: confidence,
      matchedKeywords: best?.keywords ?? []
    )
  }

  static func suggestedTitle(from text: String, fallback: String) -> String {
    let lines = text
      .components(separatedBy: .newlines)
      .map(Self.compactWhitespace)
      .filter { !$0.isEmpty }

    let candidates = lines.prefix(16).enumerated().compactMap { index, original -> TitleCandidate? in
      let line = stripTitlePrefix(original)
      guard
        line.count >= 2,
        line.count <= 80,
        line.rangeOfCharacter(from: .letters) != nil,
        !hasMetadataPrefix(line)
      else {
        return nil
      }

      let digitCount = line.filter(\.isNumber).count
      let punctuationCount = line.filter { $0.isPunctuation }.count
      let characterCount = max(line.count, 1)
      guard Double(digitCount) / Double(characterCount) < 0.55 else { return nil }

      var score = 24 - min(index, 12)
      if 3 ... 36 ~= line.count { score += 8 }
      if punctuationCount <= 1 { score += 4 }
      if line.contains("@") || line.contains("http") { score -= 12 }
      if line.range(of: #"\d{2,4}[-./]\d{1,2}[-./]\d{1,2}"#, options: .regularExpression) != nil {
        score -= 8
      }
      return TitleCandidate(text: String(line.prefix(48)), score: score)
    }

    return candidates.max { lhs, rhs in lhs.score < rhs.score }?.text ?? fallback
  }

  private static func compactWhitespace(_ text: String) -> String {
    text
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func stripTitlePrefix(_ line: String) -> String {
    let lowercased = line.lowercased()
    for prefix in ["제목:", "제목 :", "subject:", "subject :"] where lowercased.hasPrefix(prefix) {
      return compactWhitespace(String(line.dropFirst(prefix.count)))
    }
    return line
  }

  private static func hasMetadataPrefix(_ line: String) -> Bool {
    let lowercased = line.lowercased()
    return [
      "주소:", "전화:", "사업자", "일자:", "날짜:", "합계:", "금액:",
      "수신:", "참조:", "담당자:", "email:", "tel:", "date:", "total:",
    ].contains { lowercased.hasPrefix($0) }
  }

  private static func categoryOrder(_ category: DocumentCategory) -> Int {
    DocumentCategory.allCases.firstIndex(of: category) ?? .max
  }

  private struct Keyword: Sendable {
    let term: String
    let weight: Int
  }

  private struct Rule: Sendable {
    let category: DocumentCategory
    let keywords: [Keyword]
  }

  private struct RuleMatch {
    let category: DocumentCategory
    let score: Int
    let keywords: [String]
  }

  private struct TitleCandidate {
    let text: String
    let score: Int
  }

  private static let rules: [Rule] = [
    Rule(category: .receipt, keywords: [
      Keyword(term: "영수증", weight: 4), Keyword(term: "결제", weight: 2),
      Keyword(term: "승인번호", weight: 3), Keyword(term: "receipt", weight: 4),
      Keyword(term: "card total", weight: 3),
    ]),
    Rule(category: .invoice, keywords: [
      Keyword(term: "청구서", weight: 4), Keyword(term: "세금계산서", weight: 5),
      Keyword(term: "공급가액", weight: 3), Keyword(term: "invoice", weight: 4),
      Keyword(term: "amount due", weight: 3),
    ]),
    Rule(category: .contract, keywords: [
      Keyword(term: "계약서", weight: 5), Keyword(term: "계약 당사자", weight: 3),
      Keyword(term: "계약 기간", weight: 2), Keyword(term: "agreement", weight: 4),
      Keyword(term: "terms and conditions", weight: 3),
    ]),
    Rule(category: .identity, keywords: [
      Keyword(term: "주민등록증", weight: 5), Keyword(term: "운전면허증", weight: 5),
      Keyword(term: "여권", weight: 4), Keyword(term: "생년월일", weight: 2),
      Keyword(term: "passport", weight: 4), Keyword(term: "date of birth", weight: 2),
    ]),
    Rule(category: .academic, keywords: [
      Keyword(term: "학습", weight: 2), Keyword(term: "강의", weight: 2),
      Keyword(term: "과제", weight: 3), Keyword(term: "논문", weight: 3),
      Keyword(term: "참고문헌", weight: 3), Keyword(term: "lecture", weight: 2),
      Keyword(term: "homework", weight: 3), Keyword(term: "references", weight: 2),
    ]),
    Rule(category: .meetingNotes, keywords: [
      Keyword(term: "회의록", weight: 5), Keyword(term: "참석자", weight: 2),
      Keyword(term: "회의 안건", weight: 3), Keyword(term: "meeting minutes", weight: 5),
      Keyword(term: "action item", weight: 3), Keyword(term: "agenda", weight: 2),
    ]),
    Rule(category: .form, keywords: [
      Keyword(term: "신청서", weight: 4), Keyword(term: "요청서", weight: 4),
      Keyword(term: "서명란", weight: 2), Keyword(term: "제출", weight: 2),
      Keyword(term: "application form", weight: 4), Keyword(term: "signature", weight: 2),
    ]),
    Rule(category: .letter, keywords: [
      Keyword(term: "수신:", weight: 2), Keyword(term: "참조:", weight: 2),
      Keyword(term: "귀하", weight: 2), Keyword(term: "드립니다", weight: 2),
      Keyword(term: "dear ", weight: 2), Keyword(term: "sincerely", weight: 2),
    ]),
  ]
}
