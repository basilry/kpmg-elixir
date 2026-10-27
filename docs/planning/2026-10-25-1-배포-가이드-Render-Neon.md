# 배포 가이드: Render Free + Neon Free (WBS 5.4)

- 작성일: 2026-10-25
- 작성자: 메인 세션
- 관련: [배포 대상 검토](2026-10-20-8-배포-대상-검토.md) (결정: A), [WBS와 마일스톤](2026-10-17-8-WBS와-마일스톤.md) 5.1, 5.4, [배포 준비 devlog](../devlog/2026-10-25-2-배포-준비.md)
- 상태: 배포 완료 (2026-10-25 첫 배포 `main` ce33571, 지금 ca96402). 주소 https://tickmark-e0ki.onrender.com 과 https://www.tickmark.6esk.com. 10-25 17:53 사용자가 인스턴스를 Free 에서 0.5c-512mb (유료) 로 바꿨다. www 의 LiveView 403 은 `check_origin: :conn` (PR #8) 으로 고쳤고, 10-27 ca96402 배포 뒤 www 에서 101 과 화면 연결을 확인했다 (5.4절). 같은 배포로 메인화면 (`/`) 에 들어가면 데모 작성자로 자동 로그인한다 (PR #9, 5.5절). 결과는 5.2-5.5절, 기록은 [첫 배포 devlog](../devlog/2026-10-25-3-Render-첫-배포와-외부-확인.md)

## 1. 구성

```
브라우저 --HTTPS/WebSocket--> Render 웹 서비스 (0.5c-512mb, 처음엔 Free. Docker, Elixir release)
                                  |  TLS (인증서와 호스트 이름 검증)
                                  v
                              Neon Free PostgreSQL (직접 연결, Singapore)
```

컨테이너가 뜰 때 하는 일 (`rel/overlays/bin/start`):

1. `bin/migrate`: 아직 안 돌린 마이그레이션만 실행한다. 무료 플랜은 셸과 one-off job 이 없어서 부팅마다 돌린다.
2. `bin/server`: Repo, Oban, PubSub, Presence, Endpoint 를 띄운다.
3. `TICKMARK_SEED_ON_BOOT=true` 이면 Endpoint 뒤에 `Tickmark.Demo.seed_on_boot/0` Task 를 띄운다. 데모 작성자가 이미 있으면 아무것도 하지 않는다. 처음이면 사용자 두 명, 누리정밀 FY2025, 합성 GL 적재, 룰 실행까지 만든다. 적재와 룰 실행은 실제 Oban job 이라 서버가 요청을 받는 동안 뒤에서 진행된다.

## 2. 저장소에 들어간 것

| 파일 | 내용 |
|---|---|
| `Dockerfile` | `mix phx.gen.release --docker` 생성본. 문서 위키가 컴파일 시점에 읽는 `docs/`, `README.md`, `TASKS.md`, `AGENTS.md` 를 `mix compile` 전에 복사. `CMD` 는 `bin/start` |
| `.dockerignore` | 생성본에 `.env`, `.env.*`, `.claude/` 제외 추가 |
| `rel/overlays/bin/start` | 마이그레이션 뒤 서버 시작 |
| `lib/tickmark/release.ex` | 생성본. `migrate/0`, `rollback/2` |
| `lib/tickmark/demo.ex` | 시드 로직 (`seeds.exs` 에서 옮김). `seed/0`, `seed_on_boot/0`, 자동 로그인이 찾는 `preparer/0` |
| `lib/tickmark_web/controllers/page_controller.ex`, `lib/tickmark_web/user_auth.ex` | 메인화면 자동 로그인과 로그아웃 뒤 멈춤 (5.5절) |
| `render.yaml` | Blueprint. 웹 서비스 `tickmark`, `plan: free`, `region: singapore`, `branch: main`. 플랜은 대시보드에서 0.5c-512mb 로 바뀌어 지금은 이 값과 다르다 (5.3절) |
| `config/runtime.exs` | DB `ssl` (기본 켬), `RENDER_EXTERNAL_HOSTNAME` 대체값, `TICKMARK_DEMO_PASSWORD`, `TICKMARK_SEED_ON_BOOT`, `TICKMARK_DEMO_AUTO_LOGIN` |
| `config/prod.exs` | 메일러를 `Swoosh.Adapters.Logger` 로. 수신자만 로그에 남고 로그인 링크는 남지 않는다. LiveView 소켓 출처 확인을 요청 호스트 기준으로 (`check_origin: :conn`, 5.4절). 메인화면 자동 로그인 켬 (`:demo_auto_login`, 5.5절) |

## 3. 환경 변수

값은 Render 대시보드에만 넣는다. 저장소, 문서, 채팅에 남기지 않는다.

| 변수 | 넣는 곳 | 값 |
|---|---|---|
| `DATABASE_URL` | Blueprint 생성 화면 (`sync: false`) | Neon 직접 연결 문자열 (4장 2단계) |
| `SECRET_KEY_BASE` | Blueprint 생성 화면 (`sync: false`) | `mix phx.gen.secret` 출력 (64자) |
| `TICKMARK_DEMO_PASSWORD` | Blueprint 생성 화면 (`sync: false`) | 데모 계정 두 개의 비밀번호, 12자 이상 |
| `TICKMARK_SEED_ON_BOOT` | `render.yaml` | `true` |
| `TICKMARK_DEMO_AUTO_LOGIN` | 넣지 않음 | 운영은 `config/prod.exs` 에서 켠다. `false` 나 `0` 을 넣으면 끈다. 개발은 기본이 꺼짐이고 `true` 나 `1` 로 켠다 (5.5절) |
| `PORT`, `RENDER_EXTERNAL_HOSTNAME` | Render 가 자동으로 넣음 | - |
| `ANTHROPIC_API_KEY` | 넣지 않음 | 없으면 Fake 클라이언트로 트리아지 |

- `SECRET_KEY_BASE` 에 Render 의 `generateValue` 를 쓰지 않는다. 44자 (256비트 base64) 라 Phoenix 가 요구하는 64바이트보다 짧다.
- Neon 의 pooled 연결 (호스트에 `-pooler`) 은 쓰지 않는다. Oban 의 Postgres notifier 가 LISTEN/NOTIFY 를 쓰는데 트랜잭션 풀링에서는 동작하지 않는다.
- Neon 이 주는 문자열의 `sslmode=require`, `channel_binding=require` 는 그대로 둬도 된다. Ecto 가 모르는 파라미터는 Postgrex 가 무시하고, TLS 는 `ssl: true` 로 켠다.

## 4. 사용자 단계

1. **PR 병합**: `feature/m2-rule-engine` 을 `main` 에 병합한다. `render.yaml` 이 `main` 을 배포한다.
2. **Neon**: 프로젝트를 만든다 (리전 AWS Asia Pacific (Singapore)). Connect 화면에서 Connection pooling 을 끄고 나온 연결 문자열을 복사한다.
3. **SECRET_KEY_BASE**: 이 저장소 터미널에서 `mix phx.gen.secret` 을 실행해 출력을 복사한다 (Claude Code 에서는 `! mix phx.gen.secret | pbcopy`).
4. **Render**: New > Blueprint 에서 GitHub 저장소 `basilry/kpmg-elixir` 를 고른다. `render.yaml` 을 읽으면 세 값을 묻는다. 2, 3 단계 값과 데모 비밀번호를 넣고 Apply.
5. **첫 배포 확인**: 서비스 로그에서 차례로 확인한다.
   - `Migrated ...` (첫 부팅에만)
   - `Running TickmarkWeb.Endpoint with Bandit ...`
   - `demo seed: created 누리정밀 주식회사 FY2025, GL import succeeded, test run completed`
6. **외부 접속 확인**: `https://<서비스 이름>.onrender.com/` 을 열면 데모 작성자 `kim.writer@example.com` 으로 자동 로그인되어 S1 업무 목록이 뜬다 (5.5절). S2 적재와 룰 실행, S4 finding, S5 결론, S6 감사 로그, `/docs` 위키를 연다. 검토자는 오른쪽 위 메뉴에서 로그아웃한 뒤 `/users/log-in` 에서 `park.reviewer@example.com` 과 데모 비밀번호로 로그인한다. 로그인 화면 위의 "메일을 보내지 않습니다" 안내가 보이면 운영 설정이 들어간 것이다.
7. **지원서**: URL 과 데모 계정을 지원서에 적는다. 데모 비밀번호는 검토자로 볼 때만 필요하다 (작성자는 자동 로그인). 비밀번호는 지원서에만 적고 저장소와 문서에는 남기지 않는다 (URL 과 계정 이메일은 문서에 있어도 된다). Free 플랜이면 첫 접속이 잠든 서버를 깨우느라 1분쯤 걸린다고 함께 적는다. 지금 플랜 (0.5c-512mb) 은 잠들지 않아 이 안내가 필요 없다 (5.3절).

## 5. 확인 결과

### 5.1 로컬 release (2026-10-25)

Docker 데몬이 꺼져 있어 이미지 빌드는 하지 않았다. 대신 같은 prod release 를 저장소 사본에서 빌드해 (`MIX_ENV=prod`, macOS arm64) 로컬 PostgreSQL 의 새 DB 에 `DATABASE_SSL=false` 로 붙여 돌렸다.

| 항목 | 결과 |
|---|---|
| `mix precommit` | 588 통과, 경고 0 |
| prod 빌드 (`deps.get`, `compile`, `assets.deploy`, `release`) | 성공. 경고는 의존성 (gettext, dns_cluster) 에서만 |
| 첫 부팅 | 마이그레이션 전부 실행, `demo seed: created ...` |
| 두 번째 부팅 | `Migrations already up`, `demo seed: demo data already exists, nothing to do` |
| 비밀번호 로그인 | `POST /users/log-in` 302, `/engagements` 에 누리정밀 표시, engagement 화면 200 |
| `/users/log-in` | `#mail-off-notice` 있음, `#local-mail-notice` 없음 |
| `/docs`, `/users/register`, digest CSS | 모두 200 |
| 로그인 메일 | 로그에 `New email delivered to kim.writer@example.com` 만, 링크는 0건 |
| 메모리 | 빈 DB 에서 첫 부팅 시드 동안 BEAM 최대 RSS 약 291 MB (`+S 1:1`, 0.2초 간격 표본). 무료 512 MB 안 |

로컬에서 확인하지 못했던 다섯 가지는 5.2절의 첫 배포에서 네 가지가 풀렸고, 남은 Linux 메모리는 5.3절에서 Render Metrics 로 확인했다.

### 5.2 Render 첫 배포 (2026-10-25)

Blueprint 로 서비스 `tickmark` (Free, Singapore, Docker) 를 만들고 `main` ce33571 을 배포했다. 시각은 KST.

| 항목 | 결과 |
|---|---|
| 무료 플랜 Docker | 막히지 않음. Blueprint 생성과 빌드가 그대로 진행 |
| Docker 이미지 빌드 (amd64) | 성공, 09:35 시작부터 약 2분 30초. `deps.compile` 51.5초, 앱 111개 파일 컴파일. 경고는 `mix.exs` 의 xref exclude 사용 중단 안내 1건 |
| 마이그레이션 | 10개 모두 실행, 약 1.5초. Neon 직접 연결에 TLS (`ssl: true`) 로 붙음 |
| 서버 시작 | `Running TickmarkWeb.Endpoint with Bandit 1.13.1 at :::10000 (http)`. Render 가 포트 10000 을 찾음 (IPv6 `::` 바인딩 문제 없음) |
| 부팅 시드 | 서버 시작 14초 뒤 `demo seed: created 누리정밀 주식회사 FY2025, GL import succeeded, test run completed`. 0.15 CPU 에서 약 14초 |
| 상태 | 09:38 `Deploy succeeded`, Live. 재시작과 메모리 초과 이벤트 없음 |
| 런타임 경고 | `libsctp.so.1` 이 없다는 ESOCK 경고 1건. SCTP 를 쓰지 않아 영향 없음 |
| 외부 HTTP (curl) | `/` 200 (0.38초), `/users/log-in`, `/users/register`, `/docs` 200. `/engagements` 302 (로그인으로), 없는 경로 404, http 는 https 로 301. digest CSS, JS 200 |
| 운영 설정 | 로그인 화면에 `#mail-off-notice` 있음, `#local-mail-notice` 없음 |
| 응답 헤더 | HSTS (`max-age=31536000`), CSP (`base-uri 'self'; frame-ancestors 'self';`), `x-content-type-options: nosniff`, 세션 쿠키 `secure`, `HttpOnly`, `SameSite=Lax` |
| 로그인 | 사용자가 `kim.writer@example.com` 과 데모 비밀번호로 로그인. 세 값이 맞게 들어간 것도 여기서 확인됨 (아래) |
| 화면 (읽기만) | S1 누리정밀 FY2025 (최근 테스트 완료, 검토 큐 52), S2 전표 8,341건, 라인 19,804건, 적재 1건과 실행 1건, S4 룰 8/8 완료, 적중 전표 265건, 검토 큐 52, 경미 213, S5 JE2025-008261 (점수 55 = 10 + 20 + 25), S6 이벤트 #1-#6, `/docs` 위키. LiveView 연결됨, 콘솔 오류 0 |

- **값 세 개 확인**: Render 는 Blueprint 생성 화면의 `sync: false` 값을 점 12개로 가려 배포 전에는 볼 수 없다. 대신 결과로 확인했다. 마이그레이션 성공은 `DATABASE_URL` 과 TLS, 세션 쿠키가 붙은 200 응답은 `SECRET_KEY_BASE` 가 64바이트 이상인 것, 로그인 성공은 `TICKMARK_DEMO_PASSWORD` 를 보여 준다.
- **데모 데이터를 바꾸지 않음**: 확인은 페이지를 여는 것만 했다. 실행 시작, 결론 제출, 승인, AI 요청은 누르지 않았다. 감사 로그가 append-only 라 누르면 데모 데이터에 영구히 남는다.
- **Linux 메모리**: 첫 배포 때는 무료 플랜이라 메모리, CPU 지표가 보이지 않아 메모리 초과 이벤트가 없었다는 것까지만 알았다. 플랜을 바꾼 뒤 Metrics 에 첫 배포부터의 기록이 보여 5.3절에 적었다.
- **보안 권고**: `mix deps.get` 이 `plug_crypto` 2.2.0 의 [EEF-CVE-2026-105963](https://osv.dev/vulnerability/EEF-CVE-2026-105963) (MEDIUM, GHSA-ffw9-w85g-f2vh) 을 알렸다. 타입이 틀린 인자로 `Plug.Crypto` 를 부르면 스택 트레이스 인자에 secret key base 가 나올 수 있다는 내용이다. 2.2.1 에서 고쳐졌다 (10/23). 5.3절에서 2.2.1 로 올려 재배포했다 (PR #5).

### 5.3 플랜 변경과 `plug_crypto` 재배포 (2026-10-25)

17:53 사용자가 대시보드에서 인스턴스를 Free 에서 0.5c-512mb (0.5 CPU, 512 MB, 유료) 로 바꿨다. 이어서 PR #4 (첫 배포 기록 문서) 와 PR #5 (`plug_crypto` 2.2.1) 를 `main` 에 병합해 9629df7 이 배포됐다. 시각은 KST.

| 항목 | 결과 |
|---|---|
| 플랜 변경 | 이벤트 "Compute plan updated by you", "Compute plan changed from Free to 0.5c-512mb". 같은 커밋 ce33571 이 새 인스턴스로 다시 배포돼 17:53 Live |
| 병합 배포 | 두 병합이 17:54 Auto-Deploy 두 개를 띄웠다. 겹친 배포 정책대로 fa01e3d 는 "Another deploy started" 로 취소되고, 두 PR 을 모두 담은 9629df7 이 배포됨 |
| 빌드 | 17:54:36 시작, 약 2분 15초. `deps.compile` 53.3초, 앱 111개 파일 7.8초. 빌드 로그는 `* Getting plug_crypto (Hex package)` 만 찍고 버전은 찍지 않는다. 빌드가 쓰는 `mix.lock` (9629df7) 의 `plug_crypto` 는 2.2.1 |
| 부팅 | `Migrations already up`, `Running TickmarkWeb.Endpoint with Bandit 1.13.1 at :::10000 (http)`, `demo seed: demo data already exists, nothing to do`. Render 가 CPU 수에 맞춰 `WEB_CONCURRENCY=1` 을 넣지만 앱은 이 값을 쓰지 않는다. `libsctp.so.1` 경고는 첫 배포와 같음 |
| 상태 | 17:56 `Deploy succeeded`, Live. 플랜을 되돌린 이벤트 없음 |
| 외부 HTTP (curl) | `/`, `/users/log-in`, `/docs` 200 (각 약 0.22초), `/engagements` 302 (로그인으로), http 는 https 로 301. 로그인 화면에 `#mail-off-notice` 있음. 헤더는 5.2절과 같음 |
| 새 문서 | `/docs` 에 devlog 2026-10-25-3 이 보임. 위키는 빌드 때 문서를 읽으므로 PR #4 의 문서가 새 이미지에 들어간 것 |
| 브라우저 | 로그인 화면에서 LiveView 연결됨 (`phx-connected`), 콘솔 오류 0. 로그인은 하지 않음 (데모 비밀번호는 사용자만 쓴다) |
| 메모리 (Linux) | Render Metrics 의 30초 간격 표본. 첫 배포 인스턴스는 시드 직후 09:39 189.45 MB, 이후 193-194 MB 로 평평 (12시간 중 최대 194.05 MB). 9629df7 인스턴스는 17:59 188.09 MB. 한도 512 MB 의 약 38%. 시드가 돈 14초 사이의 순간 최대는 표본 간격보다 짧아 확인 필요 |

- **플랜과 비용**: 0.5c-512mb 는 유료 인스턴스다. Render 문서는 유료 플랜으로 올리면 Free 제약 (15분 무접속 뒤 잠듦 등) 이 없어진다고 한다. 그래서 6장의 잠듦 행과 4장 7단계의 첫 접속 지연 안내는 Free 로 돌아갈 때만 해당한다. 요금은 확인 필요 (Render 대시보드 기준).
- **Free 동안의 잠듦**: Metrics 에서 인스턴스 이름이 세 번 바뀌었다 (09:38, 11:16, 13:05 시작, 사이에 공백). 15분 무접속 뒤 잠들고 접속에 다시 깨어난 흔적으로 보인다. 이벤트 목록에는 따로 남지 않아 확인 필요.
- **`render.yaml` 과 어긋남**: `render.yaml` 은 아직 `plan: free` 다. Render 문서상 대시보드에서 바꾼 값이 Blueprint 와 다르면 다음 Blueprint 동기화가 덮어쓴다. 자동 동기화는 `render.yaml` 을 바꾼 push 에만 돌아서, 이번 두 병합은 플랜을 건드리지 않았다. `render.yaml` 을 고치는 PR 에서는 `plan` 을 대시보드와 맞추거나 (0.5c-512mb 에 해당하는 값 이름은 확인 필요), Blueprint 설정에서 Auto Sync 를 끈다. Free 로 돌아갈 뜻이면 그대로 둔다.
- **겹친 배포**: 연달아 병합하면 앞 배포가 취소된다. 뒤 커밋이 앞 커밋을 포함하므로 결과는 같다.

### 5.4 PR #6 재배포와 커스텀 도메인 (2026-10-25)

18:10 PR #6 (문서) 를 담은 d4c3733 이 배포됐다. 이어서 서비스에 커스텀 도메인이 연결된 것을 보고 외부에서 확인했다. 시각은 KST.

| 항목 | 결과 |
|---|---|
| 재배포 | d4c3733, Auto-Deploy 59.3초, 18:10 Live. 부팅 로그는 5.3절과 같음 (`Migrations already up`, Bandit, 시드 건너뜀) |
| 외부 HTTP | `/`, `/users/log-in`, `/docs` 200, `/engagements` 302, http 는 https 로 301, `#mail-off-notice` 있음. `/docs` 의 이 가이드에 5.3절이 보임. LiveView 연결됨, 콘솔 오류 0 |
| 커스텀 도메인 | 대시보드 서비스 머리글의 주 URL 이 `www.tickmark.6esk.com` 이고 도메인이 2개 더 있다고 나온다. Settings 의 Custom Domains 칸은 열리지 않아 목록과 인증서 상태는 확인 필요. DNS 는 `www.tickmark.6esk.com`, `tickmark.6esk.com` 둘 다 CNAME `tickmark-e0ki.onrender.com` |
| `tickmark.6esk.com` | 인증서 있음 (CN=tickmark.6esk.com, Google Trust Services WE1). https 로 열면 `https://www.tickmark.6esk.com/` 로 301 |
| `www.tickmark.6esk.com` | TLS 핸드셰이크 실패 (SSL alert 40). 이 이름의 인증서가 아직 없는 것으로 보인다 (확인 필요). http 로 열면 Render 앞단 (`Server: cloudflare`) 이 같은 호스트의 https 로 301 |
| LiveView 출처 (d4c3733) | onrender 주소의 `/live/websocket` 에 Origin 헤더만 바꿔 WebSocket 업그레이드를 보냄. Origin `https://tickmark-e0ki.onrender.com` 101, `https://www.tickmark.6esk.com` 403 (18:20 재확인). www 인증서가 나와도 그 주소의 LiveView 화면은 연결되지 않는 상태였다 |
| 10-27 재확인 (23:22) | `www.tickmark.6esk.com` 인증서 있음 (Google Trust Services WE1, notBefore 2026-10-25 08:23:59 GMT, 17:23 KST). 18:20 점검 직전에 발급됐지만 그때는 아직 쓰이지 않았던 것으로 보인다 (확인 필요). www `/` 200. 배포는 그대로 d4c3733 이고 Origin www 403, onrender 101 |
| 10-27 재배포 (ca96402) | 메인 세션이 PR #7 을 닫고 (#8 을 가리키는 댓글) PR #8 (1ab32f7), PR #9 (ca96402) 를 병합했다. #8 의 배포는 #9 의 배포가 시작되며 취소됐고 ca96402 가 Auto-Deploy 2분 5초로 Live. 새 devlog 주소가 23:45:24 에 200 이 되어 새 빌드가 뜬 것을 알았다. 부팅 로그는 이번에 보지 않았다 |
| LiveView 출처 (ca96402, 23:45) | 각 주소에 그 주소의 Origin 으로 업그레이드를 보냄. www 101, onrender 101. 다른 사이트 Origin (`https://evil.example.com`) 과 http Origin 을 www 로 보내면 403. onrender 주소에 www Origin 을 보내면 이제 403 이다. `:conn` 은 Origin 을 요청 호스트와 비교하므로 맞는 동작이다 |
| 브라우저 www | `/` 가 `/engagements` 로 가고 `liveSocket.isConnected()` 가 true, 콘솔 오류 0. 이 주소의 LiveView 화면이 처음 동작했다 |

- **원인**: Phoenix 소켓의 기본 출처 확인 (`check_origin: true`) 은 Origin 의 호스트를 endpoint `url` 호스트와만 비교한다. `url` 호스트는 `PHX_HOST` 가 없으면 `RENDER_EXTERNAL_HOSTNAME` (onrender 주소) 다. 일반 HTTP 요청은 이 확인을 거치지 않아 다른 도메인에서도 200 이 나온다.
- **수정**: `config/prod.exs` 에 `check_origin: :conn`. Origin 의 스킴, 호스트, 포트가 요청 자체와 같을 때만 소켓을 연다. `runtime.exs` 의 `url` 호스트는 그대로 두고 주석만 고쳤다.
- **검토한 대안**: Render 에 `PHX_HOST=www.tickmark.6esk.com` 을 넣으면 코드 변경은 없지만 onrender 주소의 LiveView 가 끊긴다. 허용 목록 (`check_origin: ["//tickmark-e0ki.onrender.com", "//www.tickmark.6esk.com"]`) 은 가장 좁지만 도메인이 바뀔 때마다 고쳐야 한다. 두 주소를 다 살리고 목록 관리가 없는 `:conn` 을 골랐다.
- **보안**: 출처 확인은 다른 사이트의 페이지가 사용자의 쿠키로 소켓을 여는 것 (cross-site WebSocket hijacking) 을 막는다. 그런 페이지에서 브라우저는 그 사이트를 Origin 으로, 우리 주소를 Host 로 보내므로 `:conn` 에서도 거부된다. 둘을 같게 만들려면 공격자 도메인이 우리 서버를 가리켜야 하는데, 그때 브라우저는 우리 도메인의 세션 쿠키를 보내지 않는다.
- **프록시 뒤 스킴과 포트**: Render 는 TLS 를 앞단에서 끝내고 앱에는 http 로 보낸다. 그대로면 요청은 http, 80 이고 Origin 은 https, 443 이라 `:conn` 이 모두 거부한다. `force_ssl` 의 `rewrite_on: [:x_forwarded_proto]` 가 스킴과 포트를 https, 443 으로 고치고, Phoenix endpoint 는 `Plug.SSL` 을 소켓 처리 (`socket_dispatch`) 보다 먼저 둔다. 그래서 소켓은 고쳐진 값을 본다.
- **테스트**: `test/tickmark_web/socket_origin_test.exs` (4개). `config/prod.exs` 를 `Config.Reader` 로 읽어 값이 `:conn` 인지 본다. 운영의 `rewrite_on` 으로 프록시 요청을 흉내 내 두 주소는 통과, 다른 사이트, 접미사 위장 (`www.tickmark.6esk.com.evil.example`), http Origin 은 403 인지 본다. 기본값 `true` 가 url 호스트가 아닌 도메인을 거부하는 것도 남겼다. `prod.exs` 에서 `rewrite_on` 을 비우면 2개, `check_origin` 을 지우면 1개가 실패하는 것을 확인했다.
- **병합 뒤 확인 (10-27 완료)**: 위 표의 ca96402 행. 확인 방법이 바뀐다. 수정 전에는 onrender 주소 하나에 Origin 만 바꿔 보냈지만, `:conn` 에서는 Origin 이 요청 호스트와 같아야 하므로 www 는 www 주소로 보낸다.
- **기록**: DNS, CAA, 인증서 점검과 대안 비교는 [devlog](../devlog/2026-10-25-4-커스텀-도메인과-check_origin.md). 같은 문제를 환경 변수 목록으로 푼 PR #7 은 이 수정과 배타적이라 10-27 에 닫았다.
- **학습 포인트**: 소켓 연결은 라우터를 거치지 않는다. endpoint 의 `socket` 선언을 `plug :socket_dispatch` 가 라우터보다 먼저 처리하므로, 라우터 파이프라인 대신 endpoint 설정과 소켓 옵션 (`check_origin`, `connect_info`) 이 이 요청을 다룬다. `check_origin` 값은 런타임에 endpoint 설정에서 읽어 처음 한 번 캐시한다.

### 5.5 메인화면 자동 로그인 (2026-10-27)

사용자 요청으로 메인화면에 들어가면 데모 작성자로 로그인하게 했다. 운영 배포는 합성 데이터만 담은 공개 데모 하나다. 결정과 대안은 [devlog](../devlog/2026-10-27-1-데모-자동-로그인.md) 에 있다.

| 상황 | `GET /` 결과 |
|---|---|
| 로그인 안 함, 자동 로그인 켬, 데모 작성자 있음 | 작성자로 로그인 (새 세션 토큰). 302 `/` 를 거쳐 `/engagements`. 안내 메시지에 계정과 "검토자로 보려면 로그아웃한 뒤 로그인" |
| 데모 시드 전 (작성자 없음) | 홈 화면 |
| 이 브라우저에서 로그아웃한 뒤 | 홈 화면. 세션에 `:demo_auto_login_off` 가 남아 다시 로그인시키지 않는다. 세션 쿠키라 브라우저를 닫으면 사라지고, 다시 로그인해도 지워진다 |
| 이미 로그인함 | 바뀌지 않음. `/engagements` 로 |
| `/` 가 아닌 주소로 바로 들어옴 | 바뀌지 않음. 로그인 화면으로 |

로컬 확인 (dev, `PORT=4010 TICKMARK_DEMO_AUTO_LOGIN=true`):

| 항목 | 결과 |
|---|---|
| 브라우저 `/` | `/engagements` 에 누리정밀, 자동 로그인 안내 |
| 오른쪽 위 메뉴의 로그아웃, 다시 `/` | 홈 화면 그대로 |
| `demo_auto_login_test.exs` | 6개 통과. 변이 5개 (로그아웃 표시 제거, 표시 확인 제거, 설정 확인 제거, 변수 해석 느슨하게, 운영 기본값 끔) 가 각각 해당 테스트 하나에서 실패 |

배포 뒤 확인 (ca96402, 10-27 23:46 KST, 메인 세션):

| 항목 | 결과 |
|---|---|
| curl, 쿠키 없이 `/` (onrender, www) | 두 주소 모두 리다이렉트 2번 (`/` -> `/` -> `/engagements`) 뒤 200. 본문에 자동 로그인 안내, `kim.writer@example.com`, 누리정밀이 있다. 받은 쿠키로 `/` 를 다시 부르면 302 `/engagements` |
| 브라우저 www `/` | `/engagements`, 안내 메시지 "데모 작성자 계정(kim.writer@example.com)으로 자동 로그인했습니다...", LiveView 연결, 콘솔 오류 0 |
| www 로그아웃 뒤 | 오른쪽 위 메뉴의 로그아웃으로 홈과 "로그아웃했습니다." 안내. `/` 를 다시 열어도 홈 (`#home-login`). 홈은 LiveView 가 없는 컨트롤러 화면이라 소켓 연결이 없는 것이 맞다 |
| 브라우저 onrender `/` | `/engagements`, LiveView 연결. 안내 메시지는 없었다. 이 브라우저에 앞선 점검의 onrender 세션이 남아 "이미 로그인함" 행을 탄 것으로 보인다 (확인 필요). 안내는 위 curl 에서 확인했다 |
| 안내 메시지 위치 | 안내 (flash, `toast-top toast-end`) 가 오른쪽 위 사용자 메뉴를 덮는다. 브라우저 패널 (폭 619px) 에서 첫 클릭이 메뉴 대신 안내를 닫았고, 닫은 뒤에는 메뉴가 열렸다. 6장 행으로 남김 |

점검으로 생긴 세션 토큰은 쿠키 없는 curl `GET /` 세 번 (onrender 2, www 1) 의 행 3개다. 브라우저 www 세션은 로그아웃으로 지웠다.

## 6. 알려진 제약과 대응

| 제약 | 영향 | 대응 |
|---|---|---|
| Free 에서 15분 무접속 뒤 잠듦, 깨우기 약 1분 | 첫 접속이 느리다 | 10/25 17:53 부터 0.5c-512mb 라 잠들지 않는다 (5.3절). Free 로 돌아가면 면접 2-3분 전에 URL 을 연다. 열린 LiveView 탭이 heartbeat 를 보내 시연 중에는 잠들지 않는다 |
| 메일 없음 | 새로 가입한 계정은 로그인 링크를 못 받는다 | 로그인, 회원가입 화면에 안내. 데모 계정만 쓴다 |
| 디스크 없음 | 업로드한 GL 원본은 `/tmp` 에 있고 재시작 때 사라진다 | 적재된 분개는 DB 에 있어 화면은 그대로다. 적재 중에 재시작되면 그 적재는 실패로 끝날 수 있다 |
| 무료 Docker 가 막힘 | 배포 불가 | 10/25 첫 배포에서는 막히지 않았다. 정책이 바뀌면 Render 네이티브 Elixir 런타임 (Elixir 1.20, OTP 29 지원 확인 필요) 또는 [검토](2026-10-20-8-배포-대상-검토.md) 의 B 안 Fly.io 로 같은 Dockerfile 을 쓴다 |
| 포트를 못 찾는다는 배포 실패 | 서비스가 안 뜬다 | 10/25 첫 배포에서 `::` 바인딩으로 포트 10000 을 찾았다. 앞으로 실패하면 `runtime.exs` 의 `ip` 를 `{0, 0, 0, 0}` 으로 바꾼다 |
| Free 의 CPU 0.15, 메모리 지표 없음 | 무거운 작업이 느리다. 메모리 여유를 볼 수 없다 | 시드 전체가 약 14초라 데모에는 충분했다. 0.5c-512mb 는 CPU 0.5 이고 Metrics 에서 메모리를 본다 (약 190 MB, 5.3절) |
| `render.yaml` 의 `plan: free` 와 대시보드 플랜이 다름 | `render.yaml` 을 바꾼 push 가 동기화되면 Free 로 돌아간다 | `render.yaml` 을 고칠 때 `plan` 을 맞추거나 Auto Sync 를 끈다 (5.3절) |
| 커스텀 도메인 `www.tickmark.6esk.com` 의 LiveView 403 (해결) | 10-27 ca96402 배포 전까지 www 화면이 그려지기만 하고 동작하지 않았다. `tickmark.6esk.com` 은 www 로 301 | `check_origin: :conn` (5.4절, PR #8). 10-27 23:45 배포 뒤 www Origin 101, 브라우저에서 LiveView 연결 확인. 이제 두 주소 모두 쓸 수 있다 |
| 공개 데모 자동 로그인: 방문자 모두가 작성자 | 방문자가 남긴 결론, 업로드, 테스트 실행이 Neon 과 append-only 감사 로그에 영구히 남고 다음 방문자에게 보인다 | 합성 데이터라 받아들인다. 어지러워지면 아래 "데모 데이터를 처음 상태로" 행대로 다시 만든다. 끄려면 Render 에 `TICKMARK_DEMO_AUTO_LOGIN=false` 를 넣고 다시 배포한다 (5.5절) |
| 쿠키 없는 `GET /` 마다 세션 토큰 | 봇, 링크 미리보기, 상태 확인 요청도 `users_tokens` 에 행을 하나씩 남긴다. 토큰은 14일 뒤 무효가 되지만 지우는 job 은 없다 | 행이 작아 데모 기간에는 둔다. Render 상태 확인이 `/` 를 부르는지는 확인 필요 (`render.yaml` 에 `healthCheckPath` 없음). 늘어나면 만료 토큰 정리 job 을 더한다 |
| 자동 로그인 직후 sudo 모드 | 로그인 뒤 10분 동안 설정 화면이 열려 방문자가 작성자 비밀번호를 바꿀 수 있다. 바꾸면 작성자의 세션이 모두 끊긴다. 이메일 변경은 확인 메일이 없어 끝나지 않는다 | 자동 로그인은 비밀번호를 쓰지 않아 다음 방문자는 그대로 들어온다. 지원서의 작성자 비밀번호만 안 맞게 된다. 검토자는 영향 없다 |
| 자동 로그인 안내가 사용자 메뉴를 덮음 | 안내가 오른쪽 위에 떠서 로그아웃 메뉴를 가린다. 안내 문구가 로그아웃하라고 하는데 첫 클릭은 안내를 닫는다. 폭 619px 에서 확인했고 넓은 화면에서도 겹치는지는 확인 필요 | 안내를 닫은 뒤 메뉴를 연다. 고치려면 안내를 아래쪽에 띄우거나 메뉴 아래로 내린다 (코드 변경, 이번에는 하지 않음) |
| 검토자는 로그아웃 뒤에만 | 자동 로그인은 작성자만 한다 | 안내 메시지와 지원서에 적는다. 두 역할을 함께 보려면 다른 브라우저 (시크릿 창 포함) 에서 로그아웃하고 검토자로 로그인한다 |
| 데모 데이터를 처음 상태로 | - | Neon 에서 DB 를 지우고 다시 만든 뒤 Render 에서 다시 배포한다. 부팅 때 마이그레이션과 시드가 다시 돈다 |

## Changelog

- 2026-10-25: 최초 작성. 구성, 환경 변수, 사용자 단계, 로컬 release 확인 결과, 제약
- 2026-10-25: 첫 배포 결과 (5.2절). 상태를 배포 완료로, 확인 필요 다섯 가지 중 네 가지 해결 (Linux 메모리만 남음), 6장 Docker 와 포트 행 갱신, CPU 0.15 행 추가, `plug_crypto` 보안 권고. 4장 7단계를 "비밀번호만 지원서에" 로 분명히 함
- 2026-10-25: 플랜 변경 (사용자, Free -> 0.5c-512mb) 과 `plug_crypto` 2.2.1 재배포 결과 (5.3절, 9629df7). Linux 메모리 확인 필요를 Render Metrics 로 해소. 6장 잠듦과 CPU 행 갱신, `render.yaml` 플랜 어긋남 행 추가. 상태 줄, 구성도, 2장 `render.yaml` 행, 4장 7단계 갱신
- 2026-10-25: d4c3733 재배포와 커스텀 도메인 확인 (5.4절). www 인증서 없음, www Origin 의 LiveView 403 원인과 `check_origin: :conn` 수정, 테스트, 병합 뒤 확인 항목. 상태 줄, 2장 `config/prod.exs` 행, 6장 커스텀 도메인 행
- 2026-10-27: 커스텀 도메인 재확인 (5.4절). www 인증서 발급 확인, www 200, d4c3733 의 Origin www 403 그대로. PR #7 의 점검 기록을 devlog 2026-10-25-4 로 옮기고 링크. 상태 줄, 6장 커스텀 도메인 행
- 2026-10-27: 메인화면 자동 로그인 (5.5절, `feature/demo-auto-login`). 2장 `demo.ex`, `runtime.exs`, `prod.exs` 행과 화면 코드 행, 3장 `TICKMARK_DEMO_AUTO_LOGIN` 행, 4장 6, 7단계 (작성자는 자동 로그인, 비밀번호는 검토자만), 6장 행 네 개, 상태 줄
- 2026-10-27: PR #7 닫기, PR #8, #9 병합과 ca96402 배포 뒤 확인. 5.4절 행 세 개 (재배포, www 101, 브라우저 www) 와 확인 방법, 5.5절 배포 뒤 확인 표. 6장 커스텀 도메인 행을 해결로, 안내가 메뉴를 덮는 행 추가. 상태 줄
