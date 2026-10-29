# 개발 안내

## 빌드와 테스트

macOS 14 이상, Swift 6 이상이 필요합니다. 외부 Swift 패키지 의존성은 없습니다.

```sh
sh scripts/build.sh
swift test --disable-xctest
```

빌드 결과는 `build/.staging.noindex/ChatPDF.app`입니다. 로컬 ad-hoc 서명을 사용하며 Apple 공증 배포본은 아닙니다. `sh scripts/run.sh`는 앱을 `/Applications/ChatPDF.app`에 설치합니다.

Swift 6.4 Command Line Tools에서 TestingMacros 탐색 오류가 나면 다음 명령을 사용합니다.

```sh
swift test --disable-xctest -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

`PDFREADER_CHAT_SECURITY_TEST=1`을 테스트 명령 앞에 붙이면 설치된 ChatGPT app-server의 실제 도구 제한을 추가로 확인합니다. 모델에 질문하지 않으며 계정 이용량을 사용하지 않습니다.

`PDFREADER_LIVE_CHAT_TEST=1`은 합성 PDF로 실제 질문·이미지 확인·대화 재개를 검사하는 선택적 통합 테스트입니다. **본인 ChatGPT 계정의 이용량을 사용합니다.**

## 구조

- `Sources/PDFReader`: macOS 창, 메뉴, 문서 저장, ChatGPT 대화 UI.
- `Sources/PDFReaderCore`: 복사 보정, 선택, 형광펜, OCR, PDF 대화 도구와 통신.
- `Tests/PDFReaderCoreTests`: 실제 PDF를 생성해 복사·선택·주석·대화 저장 등을 검사.

이전 PDF Reader의 설정과 기록을 유지하려고 앱 식별자 `com.pdfreader.mac`과 `~/Library/Application Support/PDF Reader/` 경로를 유지합니다.

ChatGPT 연동은 별도로 설치된 앱의 실험적 app-server 인터페이스를 사용합니다. 해당 앱 업데이트 후에는 보안 통합 테스트와 실제 연결을 다시 확인해야 합니다.

## 검증 범위

복잡한 표·수식·회전 조판의 복사 정확도와 미리보기 대비 성능 동등성을 보증하지 않습니다. OCR은 영문·한글을 지원하며 작은 글자나 수식에서 오인식할 수 있습니다.

과거 논문 검증 자료, PDF 원본, 개인 경로가 포함된 `qa/`와 `tmp/`, 빌드 결과는 저장소에서 제외합니다. 테스트와 빌드에는 이 자료가 필요하지 않습니다. 개인정보 보호 및 보안 점검 결과는 [SECURITY.md](SECURITY.md)를 참고하세요.
