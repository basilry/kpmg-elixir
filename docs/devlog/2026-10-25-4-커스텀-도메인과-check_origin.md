# 커스텀 도메인 tickmark.6esk.com 점검과 check_origin 수정

- 날짜: 2026-10-25 (지원 마감일)
- 작업자: 메인 세션 (점검, 코드), 사용자 (Vercel DNS, Render 도메인 등록)
- 관련: [배포 가이드](../planning/2026-10-25-1-배포-가이드-Render-Neon.md), [Render 첫 배포 devlog](2026-10-25-3-Render-첫-배포와-외부-확인.md)

## 목표

Vercel 에서 산 `6esk.com` 의 하위 도메인 `tickmark.6esk.com` 으로 Render 의 Tickmark 를 연다. 연결 상태를 밖에서 확인하고, 앱 쪽에서 막는 것이 있으면 고친다.

## 한 일

- DNS 와 HTTP 점검 (dig, curl, openssl). 결과는 아래 "실행 결과".
- `config/runtime.exs`: `PHX_HOST` 와 `RENDER_EXTERNAL_HOSTNAME` 으로 `check_origin` 목록을 만들어 Endpoint 에 넣었다.
- `test/config/runtime_test.exs`: `config/runtime.exs` 를 prod 로 읽어 `url` 의 host 와 `check_origin` 을 확인하는 테스트 3개.
- README 운영 환경 변수 표의 `PHX_HOST` 줄 갱신.
- Render 대시보드, Render 환경 변수, Vercel DNS 는 바꾸지 않았다. 계정 설정이라 사용자가 한다.

## 실행 결과

- `6esk.com` 은 Vercel DNS (`ns1/ns2.vercel-dns.com`), 등록기관 Name.com, 만료 2027-01-31. 루트, `www`, `defense` 는 Desk 서비스가 쓰는 Vercel 주소다. 와일드카드 레코드가 있어 모르는 하위 도메인도 Vercel 로 간다.
- `tickmark.6esk.com` 과 `www.tickmark.6esk.com` 둘 다 CNAME 으로 `tickmark-e0ki.onrender.com` 을 가리킨다. 명시한 CNAME 이 와일드카드보다 앞선다.
- CAA 는 `letsencrypt.org`, `pki.goog`, `sectigo.com` 을 허용한다. `tickmark.6esk.com` 인증서는 Google Trust Services WE1, 발급 2026-10-25 08:07:48 GMT (17:07 KST).
- `https://tickmark.6esk.com/` 은 301 로 `https://www.tickmark.6esk.com/` 에 보낸다. 응답 헤더가 `server: cloudflare` 라 앱이 아니라 Render 엣지의 리다이렉트다. `www.tickmark.6esk.com` 은 인증서가 없어 TLS 핸드셰이크가 실패한다.
- 웹소켓 Origin 검사 (`/live/websocket` 업그레이드, onrender 주소로 요청): Origin 이 onrender 면 101, `tickmark.6esk.com` 과 `www.tickmark.6esk.com` 이면 403. 운영에 `PHX_HOST` 가 없다는 뜻이다.
- 수정 뒤 `mix precommit`: 경고 0, 테스트 591 passed (기존 588 + 3).

## 결정과 트레이드오프

- **목록은 환경 변수에서 만든다.** 검토한 대안:
  - `PHX_HOST=tickmark.6esk.com` 만 넣기: 코드는 그대로지만 onrender 주소가 403 이 된다. README 와 배포 가이드에 onrender 주소가 있고 지원서에도 이미 적었을 수 있어 기각.
  - `check_origin: false`: 모든 출처의 웹소켓을 받는다. 다른 사이트가 로그인한 사용자의 쿠키로 소켓을 여는 공격 (CSWSH) 을 막지 못해 기각.
  - 도메인을 코드에 적기: 환경 변수 없이 바로 되지만, 도메인이 바뀌면 코드를 고쳐야 하고 "호스트는 플랫폼 환경 변수로만" 이라는 배포 원칙과 어긋나 기각.
  - 쉼표 목록 변수 (`PHX_ALLOWED_ORIGINS` 같은): 유연하지만 지금 필요한 주소는 둘뿐이고 운영 변수가 하나 는다. 기각.
- **대가는 순서다.** 이 수정만으로는 커스텀 도메인이 열리지 않는다. 배포한 뒤 `PHX_HOST` 를 넣어야 목록에 들어간다. 대신 어느 단계에서도 onrender 주소는 깨지지 않는다.
- **`https://` 만 허용한다.** `force_ssl` 이 http 를 https 로 돌려보내므로 브라우저가 보내는 Origin 은 항상 https 다.
- **`www.tickmark.6esk.com` 은 넣지 않는다.** 하위 도메인 아래의 www 는 쓸 일이 없다. Render 와 Vercel 에서 지우는 쪽을 권했다.

## 막힌 점과 해결

- **루트가 www 로 넘어감.** Render 는 www 도메인을 등록하면 짝이 되는 주소를 자동으로 붙이고 www 쪽으로 리다이렉트한다. `www.tickmark.6esk.com` 이 Render 에 등록된 것으로 보인다 (대시보드 확인 필요). 이건 코드로 풀 수 없어 사용자 단계로 남겼다.
- **페이지는 뜨는데 동작하지 않는 증상.** Origin 검사는 소켓 업그레이드에만 걸리고 일반 HTTP 요청에는 걸리지 않는다. 그래서 첫 화면은 200 으로 그려지고 LiveView 만 붙지 않는다. 브라우저로 보기 전에 curl 로 업그레이드 요청의 Origin 을 바꿔 가며 쳐서 101 과 403 을 갈라 원인을 확정했다.

## Elixir 학습 포인트

- **`check_origin`.** `Phoenix.Socket.Transport` 가 웹소켓과 long poll 연결 때 `Origin` 헤더를 검사한다. 기본값 `true` 는 Endpoint `url` 의 host 하나와 host 만 비교한다. 목록을 주면 항목마다 `URI.parse` 로 scheme, host, port 를 나눠 셋을 모두 비교한다 (`deps/phoenix/lib/phoenix/socket/transport.ex`). `https://host` 는 포트가 443 으로 채워지고, `//host` 처럼 scheme 을 빼면 scheme 과 포트는 보지 않는다. 맞지 않으면 소켓 `connect` 전에 403 을 돌려준다. `config/dev.exs` 가 `check_origin: false` 인 건 개발 서버라서다.
- **`config/runtime.exs` 는 스크립트다.** 모듈 밖이라 `def` 로 함수를 만들 수 없다. 그래서 목록을 파이프로 바로 만든다. release 에서는 부팅 때 이 파일을 실행하므로 `System.get_env` 가 운영 값을 읽는다.
- **설정 파일 테스트.** `Config.Reader.read!("config/runtime.exs", env: :prod)` 는 파일을 실행해 설정 키워드 목록을 돌려준다. `env: :prod` 를 주면 파일 안의 `config_env()` 가 `:prod` 가 된다. 테스트가 OS 환경 변수를 바꾸므로 `async: false` 로 두고 `on_exit` 에서 원래 값으로 되돌린다. ExUnit 은 async 모듈을 먼저 다 돌린 뒤 sync 모듈을 하나씩 돌리므로 다른 테스트와 겹치지 않는다.

## 다음 할 일

1. 사용자: 이 PR 병합. Render 가 `main` 커밋으로 자동 배포한다. onrender 주소가 그대로 동작하는지 확인.
2. 사용자: Render > tickmark > Settings > Custom Domains 에서 `www.tickmark.6esk.com` 을 지우고 `tickmark.6esk.com` 만 남긴다. 같이 지워지면 `tickmark.6esk.com` 을 다시 등록한다.
3. 사용자: Vercel DNS 에서 `www.tickmark` CNAME 삭제. `tickmark` CNAME 은 그대로 둔다.
4. 사용자: Render Environment 에 `PHX_HOST=tickmark.6esk.com` 을 넣고 재배포.
5. 메인: 두 주소에서 웹소켓 101 과 로그인 화면 확인, 배포 가이드에 커스텀 도메인 절 추가.

## 관련 커밋

- 6a8e393 fix(config): LiveView 소켓이 커스텀 도메인과 Render 주소를 모두 허용
- 이 devlog 와 색인은 뒤이은 docs 커밋
