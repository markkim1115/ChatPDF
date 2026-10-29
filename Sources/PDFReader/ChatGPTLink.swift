import Foundation

enum ChatGPTLink {
    static func make(pdfURL: URL, documentName: String, page: Int, pageCount: Int) -> URL {
        let prompt = """
        PDF Reader에서 읽고 있는 PDF입니다. 아래 로컬 파일을 직접 열어 전체 내용을 읽고, 한국어로 핵심 내용을 간단히 요약해 주세요. 이어서 제가 문서에 관해 질문하겠습니다.

        문서 이름: \(documentName)
        PDF 파일: \(pdfURL.path)
        현재 보고 있는 페이지: \(page) / \(pageCount) (PDF 파일의 첫 페이지를 1로 셉니다.)

        표·그림·수식에 관한 질문에는 해당 페이지를 실제로 확인해서 답해 주세요.
        """
        var link = URLComponents()
        link.scheme = "codex"
        link.host = "new"
        link.queryItems = [URLQueryItem(name: "prompt", value: prompt),
                           URLQueryItem(name: "path", value: pdfURL.deletingLastPathComponent().path)]
        // URLSearchParams in the receiving app treats an unescaped '+' as a space.
        link.percentEncodedQuery = link.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return link.url!
    }
}
