# 배포 가이드: Render Free + Neon Free (WBS 5.4)

- 작성일: 2026-10-25
- 작성자: 메인 세션
- 관련: [배포 대상 검토](2026-10-20-8-배포-대상-검토.md) (결정: A), [WBS와 마일스톤](2026-10-17-8-WBS와-마일스톤.md) 5.1, 5.4, [배포 준비 devlog](../devlog/2026-10-25-2-배포-준비.md)
- 상태: 배포 완료 (2026-10-25, `main` ce33571). 주소 https://tickmark-e0ki.onrender.com. 결과는 5.2절, 기록은 [첫 배포 devlog](../devlog/2026-10-25-3-Render-첫-배포와-외부-확인.md)

## 1. 구성

```
브라우저 --HTTPS/WebSocket--> Render Free 웹 서비스 (Docker, Elixir release)
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
| `lib/tickmark/demo.ex` | 시드 로직 (`seeds.exs` 에서 옮김). `seed/0`, `seed_on_boot/0` |
| `render.yaml` | Blueprint. 웹 서비스 `tickmark`, `plan: free`, `region: singapore`, `branch: main` |
| `config/runtime.exs` | DB `ssl` (기본 켬), `RENDER_EXTERNAL_HOSTNAME` 대체값, `TICKMARK_DEMO_PASSWORD`, `TICKMARK_SEED_ON_BOOT` |
| `config/prod.exs` | 메일러를 `Swoosh.Adapters.Logger` 로. 수신자만 로그에 남고 로그인 링크는 남지 않는다 |

## 3. 환경 변수

값은 Render 대시보드에만 넣는다. 저장소, 문서, 채팅에 남기지 않는다.

| 변수 | 넣는 곳 | 값 |
|---|---|---|
| `DATABASE_URL` | Blueprint 생성 화면 (`sync: false`) | Neon 직접 연결 문자열 (4장 2단계) |
| `SECRET_KEY_BASE` | Blueprint 생성 화면 (`sync: false`) | `mix phx.gen.secret` 출력 (64자) |
| `TICKMARK_DEMO_PASSWORD` | Blueprint 생성 화면 (`sync: false`) | 데모 계정 두 개의 비밀번호, 12자 이상 |
| `TICKMARK_SEED_ON_BOOT` | `render.yaml` | `true` |
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
6. **외부 접속 확인**: `https://<서비스 이름>.onrender.com/users/log-in` 에서 `kim.writer@example.com` 과 데모 비밀번호로 로그인한다. 화면 위의 "메일을 보내지 않습니다" 안내가 보이면 운영 설정이 들어간 것이다. S1 업무 목록, S2 적재와 룰 실행, S4 finding, S5 결론, S6 감사 로그, `/docs` 위키를 연다. 검토자는 `park.reviewer@example.com` 으로 같은 비밀번호를 쓴다.
7. **지원서**: URL 과 데모 계정을 지원서에 적는다. 데모 비밀번호는 지원서에만 적고 저장소와 문서에는 남기지 않는다 (URL 과 계정 이메일은 문서에 있어도 된다). 첫 접속은 잠든 서버를 깨우느라 1분쯤 걸린다고 함께 적는다.

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

로컬에서 확인하지 못했던 다섯 가지는 5.2절의 첫 배포에서 네 가지가 풀렸다. Linux 메모리만 확인 필요로 남는다.

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
- **확인 필요**: Linux 에서의 메모리. 무료 플랜은 메모리, CPU 지표를 보여 주지 않는다. 시드 동안 메모리 초과 이벤트가 없었다는 것까지만 안다.
- **보안 권고**: `mix deps.get` 이 `plug_crypto` 2.2.0 의 [EEF-CVE-2026-105963](https://osv.dev/vulnerability/EEF-CVE-2026-105963) (MEDIUM, GHSA-ffw9-w85g-f2vh) 을 알렸다. 타입이 틀린 인자로 `Plug.Crypto` 를 부르면 스택 트레이스 인자에 secret key base 가 나올 수 있다는 내용이다. 2.2.1 에서 고쳐졌다 (10/23). 후속으로 `mix deps.update plug_crypto` 뒤 재배포한다.

## 6. 알려진 제약과 대응

| 제약 | 영향 | 대응 |
|---|---|---|
| 15분 무접속 뒤 잠듦, 깨우기 약 1분 | 첫 접속이 느리다 | 면접 2-3분 전에 URL 을 연다. 열린 LiveView 탭이 heartbeat 를 보내 시연 중에는 잠들지 않는다 |
| 메일 없음 | 새로 가입한 계정은 로그인 링크를 못 받는다 | 로그인, 회원가입 화면에 안내. 데모 계정만 쓴다 |
| 디스크 없음 | 업로드한 GL 원본은 `/tmp` 에 있고 재시작 때 사라진다 | 적재된 분개는 DB 에 있어 화면은 그대로다. 적재 중에 재시작되면 그 적재는 실패로 끝날 수 있다 |
| 무료 Docker 가 막힘 | 배포 불가 | 10/25 첫 배포에서는 막히지 않았다. 정책이 바뀌면 Render 네이티브 Elixir 런타임 (Elixir 1.20, OTP 29 지원 확인 필요) 또는 [검토](2026-10-20-8-배포-대상-검토.md) 의 B 안 Fly.io 로 같은 Dockerfile 을 쓴다 |
| 포트를 못 찾는다는 배포 실패 | 서비스가 안 뜬다 | 10/25 첫 배포에서 `::` 바인딩으로 포트 10000 을 찾았다. 앞으로 실패하면 `runtime.exs` 의 `ip` 를 `{0, 0, 0, 0}` 으로 바꾼다 |
| CPU 0.15, 메모리 지표 없음 | 무거운 작업이 느리다. 메모리 여유를 볼 수 없다 | 시드 전체가 약 14초라 데모에는 충분하다. 메모리는 재시작 이벤트로만 본다 |
| 데모 데이터를 처음 상태로 | - | Neon 에서 DB 를 지우고 다시 만든 뒤 Render 에서 다시 배포한다. 부팅 때 마이그레이션과 시드가 다시 돈다 |

## Changelog

- 2026-10-25: 최초 작성. 구성, 환경 변수, 사용자 단계, 로컬 release 확인 결과, 제약
- 2026-10-25: 첫 배포 결과 (5.2절). 상태를 배포 완료로, 확인 필요 다섯 가지 중 네 가지 해결 (Linux 메모리만 남음), 6장 Docker 와 포트 행 갱신, CPU 0.15 행 추가, `plug_crypto` 보안 권고. 4장 7단계를 "비밀번호만 지원서에" 로 분명히 함
