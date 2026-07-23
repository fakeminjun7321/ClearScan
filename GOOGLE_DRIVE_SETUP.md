# Google Drive · Google Docs 연결 설정

## iPhone/iPad 앱 직접 연결

네이티브 UIKit 앱은 companion 웹을 열지 않습니다. 앱의 SwiftData 문서와 FileManager 페이지를 직접 선택해 PDF로 만든 뒤 Google Drive API로 업로드합니다.

- Google Cloud iOS OAuth client: `ClearScan iOS`
- Bundle ID: 로컬 `Config/Local.xcconfig`의 `PRODUCT_BUNDLE_IDENTIFIER`
- OAuth scope: `https://www.googleapis.com/auth/drive.file`
- 기본 Drive 폴더: `ClearScan`
- 5MB 이하: multipart upload
- 5MB 초과: resumable upload
- Google Docs 선택 시: `application/vnd.google-apps.document` + `ocrLanguage=ko`

공개 iOS Client ID와 reversed callback scheme은
`ios/ClearScan/Config/Local.xcconfig`를 통해 Info.plist에 연결됩니다. iOS OAuth
client에는 client secret이 없으며 프로젝트에도 비밀키를 넣지 않습니다.
앱의 Google 탭에서 `Google 계정 연결`을 누르고 등록된 테스트 사용자로 한 번
동의하면 됩니다.

## 선택 사항: Companion Web

ClearScan Web은 Google Identity Services의 OAuth 토큰 클라이언트와 Google Drive API `drive.file` 범위를 사용합니다. 클라이언트 비밀키는 사용하지 않으며 코드나 저장소에 넣지 않습니다. Google Docs 내보내기도 Drive의 공식 문서 변환 업로드를 사용하므로 별도의 광범위한 권한이나 클라이언트 비밀키가 필요하지 않습니다.

## Google Cloud에서 한 번 설정

1. Google Cloud 프로젝트를 만들거나 개인 프로젝트를 선택합니다.
2. **Google Drive API**를 활성화합니다.
3. OAuth 동의 화면을 구성합니다. 개인 테스트 단계에서는 본인 Google 계정을 테스트 사용자로 추가합니다.
4. OAuth Client ID를 **Web application** 유형으로 만듭니다.
5. Authorized JavaScript origins에 로컬 웹 주소 `http://localhost:4173`을 추가합니다.
6. 배포 후에는 실제 HTTPS 웹 주소도 Authorized JavaScript origins에 추가합니다.
7. 리디렉션 URI를 요구하는 다른 OAuth 흐름으로 교체할 경우 해당 콜백 주소를 Authorized redirect URIs에 추가합니다. 현재 GIS 팝업 토큰 흐름은 JavaScript origin을 사용합니다.

## 로컬 환경변수

`web/.env.example`을 `web/.env.local`로 복사하고 Client ID만 넣습니다.

```env
VITE_GOOGLE_CLIENT_ID=your-google-oauth-web-client-id.apps.googleusercontent.com
```

`VITE_` 변수는 브라우저에 공개되는 OAuth Client ID 전용입니다. 클라이언트 비밀키, 서비스 계정 키, 액세스 토큰은 넣지 않습니다.

## 동작

- 사용자가 `Google 연결`을 누를 때만 Google 로그인/동의 창이 열립니다.
- 범위는 `https://www.googleapis.com/auth/drive.file`입니다.
- 사용자가 대상 폴더를 지정하지 않으면 Drive에 `ClearScan` 폴더를 찾아 사용하고, 없으면 업로드 시 생성합니다.
- 선택한 문서는 로컬 내보내기 API에서 선택한 PDF/JPEG/ZIP 형식으로 만든 뒤 순서대로 업로드합니다. 여러 JPEG 페이지는 하나의 ZIP으로 묶습니다.
- `Google Docs · 편집 가능 OCR`을 고르면 선택한 페이지를 PDF로 묶고, Drive 업로드 시 `application/vnd.google-apps.document`로 변환합니다.
- 변환 요청에는 `ocrLanguage=ko`를 사용합니다. 결과 Google Docs에는 원본 스캔과 OCR로 인식된 편집 가능한 텍스트가 포함되며, 완료 후 `열기`로 바로 수정할 수 있습니다.
- OCR 정확도는 원본 해상도, 기울기, 그림자와 글꼴에 영향을 받으므로 중요한 문서는 변환 후 텍스트를 확인해야 합니다.
- 각 문서의 진행률, 실패 원인, 재시도 버튼을 표시합니다.
- 액세스 토큰은 React 메모리 상태에만 두며 디스크나 로컬 백엔드에 저장하지 않습니다.

API 요청 형식과 오류·재시도는 자동화 테스트로 검증되어 있습니다. 실제 계정 연결에는 등록된 테스트 사용자의 Google 로그인과 최초 동의가 필요합니다.

## 네이티브 로컬 설정

공개 저장소의 기본값은 의도적으로 인증이 비활성화되어 있습니다.

```bash
cd ios/ClearScan
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

복사한 파일에서 고유 Bundle ID, Apple Team ID, iOS OAuth Client ID와 reversed
Client ID를 설정합니다. `Local.xcconfig`는 Git에서 제외됩니다. 공개 OAuth Client
ID는 비밀키는 아니지만, 각 포크가 원 소유자의 Cloud 프로젝트와 할당량을
공유하지 않도록 저장소에는 실제 값을 넣지 않습니다.

## Companion을 iPhone/iPad 브라우저에서 사용할 때

- `http://192.168.x.x:4173` 같은 Mac LAN 주소는 companion 화면과 로컬 API 확인에는 사용할 수 있습니다.
- Google OAuth 웹 클라이언트는 `localhost`만 HTTP 예외로 허용하며 raw IP의 HTTP origin은 허용하지 않습니다. 따라서 LAN 주소에서 Google 로그인은 동작하지 않습니다.
- companion 브라우저에서 Drive/Docs까지 사용하려면 companion과 API를 HTTPS 주소로 제공하고, 그 companion origin을 Google OAuth 클라이언트에 추가해야 합니다. 네이티브 앱의 직접 Google 탭에는 이 HTTPS companion 제약이 적용되지 않습니다.
