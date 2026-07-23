import XCTest

@testable import ClearScan

final class DocumentContentAnalyzerTests: XCTestCase {
  private let analyzer = DocumentContentAnalyzer()

  func testClassifiesReceiptAndUsesMerchantAsTitle() {
    let result = analyzer.analyze(text:
      """
      모닝카페 강남점
      영수증
      카드 결제
      승인번호 123456
      합계: 8,500원
      """
    )

    XCTAssertEqual(result.category, .receipt)
    XCTAssertEqual(result.suggestedTitle, "모닝카페 강남점")
    XCTAssertGreaterThan(result.confidence, 0.6)
    XCTAssertTrue(result.matchedKeywords.contains("영수증"))
  }

  func testStripsExplicitTitlePrefixAndClassifiesForm() {
    let result = analyzer.analyze(text:
      """
      수신: 관련 부서장
      제목: 업무 협조 요청서
      아래와 같이 자료 제출을 요청합니다.
      담당자: 홍길동
      """
    )

    XCTAssertEqual(result.category, .form)
    XCTAssertEqual(result.suggestedTitle, "업무 협조 요청서")
  }

  func testFallsBackToGeneralWithoutFalseClassification() {
    let result = analyzer.analyze(text: "산책 기록\n맑음\n오후 세 시")

    XCTAssertEqual(result.category, .general)
    XCTAssertEqual(result.suggestedTitle, "산책 기록")
    XCTAssertLessThan(result.confidence, 0.5)
  }
}
