# 커스텀 도메인 점검과 LiveView 출처 확인 수정

- 날짜: 2026-10-25 (지원 마감일), 2026-10-27 재확인
- 작업자: 메인 세션 (점검, 코드), 사용자 (Vercel DNS, Render 도메인 등록)
- 관련: [배포 가이드](../planning/2026-10-25-1-배포-가이드-Render-Neon.md) 5.4절, [Render 첫 배포 devlog](2026-10-25-3-Render-첫-배포와-외부-확인.md)

## 목표

Vercel 에서 관리하는 `6esk.com` 의 하위 도메인으로 Render 의 Tickmark 를 연다. 연결 상태를 밖에서 확인하고, 앱 쪽에서 막는 것이 있으면 고친다.

## 한 일

- DNS, 인증서, HTTP, WebSocket 업그레이드 점검 (dig, openssl, curl). 결과는 아래 "실행 결과".
- `config/prod.exs`: `check_origin: :conn`. `config/runtime.exs` 는 주석만 고쳤다.
- `test/tickmark_web/socket_origin_test.exs`: 테스트 4개 (가이드 5.4절).
- Render 대시보드, Render 환경 변수, Vercel DNS 는 바꾸지 않았다. 계정 설정이라 사용자가 한다.

## 실행 결과

- `6esk.com` 은 Vercel DNS (`ns1/ns2.vercel-dns.com`), 등록기관 Name.com, 만료 2027-01-31. 와일드카드 레코드가 있어 모르는 하위 도메인도 Vercel 주소 (216.198.79.65, 64.29.17.1) 로 간다.
- `tickmark.6esk.com` 과 `www.tickmark.6esk.com` 둘 다 CNAME 으로 `tickmark-e0ki.onrender.com` 을 가리킨다. 명시한 CNAME 이 와일드카드보다 앞선다.
- CAA 는 `pki.goog`, `sectigo.com`, `letsencrypt.org` 를 허용한다. 인증서는 둘 다 Google Trust Services WE1. `tickmark` 은 notBefore 08:07:48 GMT (17:07 KST), `www.tickmark` 은 08:23:59 GMT (17:23 KST). 10-25 18:20 점검 때 www 는 TLS 핸드셰이크가 실패했지만, 10-27 재확인 때는 열렸다 (200).
- `https://tickmark.6esk.com/` 은 `https://www.tickmark.6esk.com/` 으로 301. 응답 헤더가 `server: cloudflare` 라 앱이 아니라 Render 엣지의 리다이렉트다. 그래서 www 가 사실상 주 주소다.
- WebSocket 출처 (`/live/websocket` 업그레이드, onrender 주소로 요청, d4c3733): Origin 이 onrender 면 101, www 면 403. 10-25 18:20, 10-27 23:22 두 번 같았다. www 화면은 200 으로 그려지지만 LiveView 가 붙지 않는다.
- 수정 뒤 `mix precommit`: 경고 0, 592 tests 통과.

## 결정과 트레이드오프

- **`check_origin: :conn` 을 골랐다.** Origin 의 스킴, 호스트, 포트가 요청 자체와 같을 때만 소켓을 연다. 검토한 대안:
  - `PHX_HOST` 를 커스텀 도메인으로: 코드 변경은 없지만 onrender 주소가 403 이 된다. 기각.
  - 환경 변수 (`PHX_HOST`, `RENDER_EXTERNAL_HOSTNAME`) 로 허용 목록 만들기: 같은 문제를 푼 PR #7 의 방식이다. 배포 뒤 대시보드에서 `PHX_HOST` 를 넣어야 동작하고, 루트가 www 로 넘어가는데 www 는 목록에 없었다. 기각.
  - 도메인을 코드에 적은 정적 목록: 가장 좁지만 도메인이 바뀔 때마다 고쳐야 한다. 기각.
  - `check_origin: false`: 다른 사이트가 로그인한 사용자의 쿠키로 소켓을 여는 공격 (CSWSH) 을 막지 못한다. 기각.
- **`:conn` 의 대가.** 허용 범위를 "이 서버로 온 요청의 호스트" 로 넓힌다. 다른 사이트의 페이지에서는 Origin 과 Host 가 달라 여전히 거부된다. 근거와 프록시 뒤 스킴 처리는 가이드 5.4절에 적었다.

## 막힌 점과 해결

- **페이지는 뜨는데 동작하지 않는 증상.** 출처 확인은 소켓 업그레이드에만 걸린다. 브라우저로 보기 전에 curl 로 Origin 만 바꿔 101 과 403 을 갈라 원인을 확정했다.
- **같은 문제로 PR 이 두 개 생겼다.** 병렬로 연 세션 두 곳이 각자 고쳐 PR #7 (환경 변수 목록) 과 PR #8 (`:conn`) 이 나왔다. 둘은 `runtime.exs` 에서 충돌하고 서로 배타적이다. PR #8 을 남기고 PR #7 의 점검 기록을 이 문서로 옮겼다. 교훈: 수정을 시작하기 전에 열린 PR 과 원격 브랜치를 먼저 본다.

## Elixir 학습 포인트

- **`check_origin`.** `Phoenix.Socket.Transport` 가 WebSocket 과 long poll 연결 때 `Origin` 헤더를 검사한다. 기본값 `true` 는 Origin 호스트를 endpoint `url` 호스트와만 비교한다. 목록을 주면 항목마다 scheme, host, port 를 비교하고, `:conn` 은 요청 conn 의 값과 비교한다. 맞지 않으면 소켓 `connect` 전에 403 을 돌려준다.
- **소켓은 라우터를 거치지 않는다.** endpoint 의 `socket` 선언을 `socket_dispatch` 가 라우터보다 먼저 처리한다. 그래서 라우터 파이프라인이 아니라 endpoint 설정이 이 요청을 다룬다.
- **설정 파일 테스트.** `Config.Reader.read!("config/prod.exs", env: :prod)` 는 파일을 실행해 설정 키워드 목록을 돌려준다. `prod.exs` 는 환경 변수를 읽지 않아 테스트에서 그대로 읽을 수 있다.

## 다음 할 일

1. 사용자: PR #8 병합 (Render 자동 배포). PR #7 은 닫는다.
2. 메인: 배포 뒤 Origin www 가 101 인지, onrender 가 계속 101 인지, 브라우저로 www 의 LiveView 가 붙는지 확인.

## 관련 커밋

- afa8888 fix(web): LiveView 출처 확인을 요청 호스트 기준으로 바꾼다
- 이 devlog 와 가이드 재확인은 뒤이은 docs 커밋
