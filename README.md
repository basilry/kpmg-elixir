# Tickmark

감사인과 AI 에이전트가 함께 일하는 감사 Work OS의 축소판이다. 첫 대상 업무는 분개 테스트(Journal Entry Testing)다.

삼정KPMG Audit Innovation Software Engineer 지원 포트폴리오로, Elixir를 처음 배우면서 만들고 있다. 개발 과정과 설계 결정은 [docs/devlog/](docs/devlog/)에 날짜순으로 남긴다.

## 목표

분개 테스트는 회사의 총계정원장(GL) 전체에서 부정이나 오류 위험이 큰 전표를 골라 감사인이 들여다보는 절차다. Tickmark는 이 흐름을 한 화면 흐름으로 묶는다.

```
GL 적재 -> 룰 8종 병렬 실행 -> 위험 점수로 전표 선별 -> AI 트리아지 제안
       -> 작성자 결론 -> 검토자 승인/반려 -> 감사 로그
```

제품 원칙은 세 가지다.

1. **AI는 제안하고, 판단과 서명은 사람이 한다.** AI 결과는 별도 테이블에 불변으로 저장하고 전표 상태를 바꾸지 않는다. 결론이 어떤 AI 제안을 보고 내려졌는지 `ai_triage_id`로 추적한다.
2. **모든 행위는 append-only 감사 로그에 남는다.** 상태 변경과 감사 이벤트를 한 트랜잭션에 쓰고, DB 트리거가 감사 로그의 UPDATE/DELETE를 거부한다.
3. **직무분리(SoD).** 결론을 낸 사람은 그 결론을 승인할 수 없다. 컨텍스트 코드와 DB 제약(CHECK, 복합 FK) 양쪽에서 막는다.

데이터는 합성 데이터만 쓴다. 실제 고객이나 회사 데이터는 저장소에 넣지 않는다.

## 화면

| 화면 | 경로 | 하는 일 | 상태 |
|---|---|---|---|
| S1 감사 대상 목록 | `/engagements` | 감사 대상 생성, 내가 멤버인 대상과 최근 실행 상태 | 완료 |
| S2 감사 대상 상세 | `/engagements/:id` | 멤버 관리, GL 적재 이력, 테스트 실행 | 완료 |
| S3 GL 불러오기 | `/engagements/:id/imports/new` | CSV 업로드 또는 시드 기반 합성 GL 생성 | 완료 |
| S4 테스트 실행 | `/engagements/:id/runs/:run_id` | 룰별 진행률 (실시간), 위험 전표 목록 | 완료 (AI 열은 개발 중) |
| S5 전표 검토 | `/engagements/:id/findings/:finding_id` | 룰 근거, AI 제안, 작성자 결론, 검토자 승인/반려 | 표시 완료. AI 요청, 결론 제출, 승인/반려 동작은 개발 중 |
| S6 감사 로그 | `/engagements/:id/audit` | 행위자, 전표별 필터와 실시간 새 이벤트 | 완료 |

화면별 상세 명세는 [화면설계서](docs/design/2026-10-17-13-화면설계서.html)에 있다.

### 분개 테스트 룰

| rule_id | 이름 |
|---|---|
| `period_end_manual` | 기말 수기 전표 |
| `round_amount` | 라운드 금액 |
| `approval_control_gap` | 승인 통제 이탈 |
| `backdated_posting` | 증빙일 괴리 |
| `weekend_holiday_posting` | 주말/공휴일 전기 |
| `off_hours_entry` | 업무시간 외 입력 |
| `duplicate_entry` | 중복 전표 의심 |
| `rare_account_pair` | 희귀 계정 조합 |

전표마다 적중한 룰의 가중치를 더해 점수(최대 100)를 만들고, 기준(기본 25) 이상인 전표가 검토 큐에 들어간다. 룰 정의, 가중치, 합성 데이터의 정답 라벨은 [도메인 문서](docs/domain/2026-10-17-3-분개테스트-룰과-감사-용어.md)에 있다.

## 아키텍처

```
 Browser (LiveView JS)
   | HTTP + WebSocket
   v
 TickmarkWeb.Endpoint (Bandit) -> Router -> UserAuth (current_scope)
   |
   +-- LiveViews: EngagementLive, ImportLive, TestRunLive, FindingLive, AuditLive
   |       | 호출: 항상 scope 가 첫 인자              ^ handle_info
   v       v                                         |
 Contexts ----------------------------------------> Phoenix.PubSub (+ Presence)
   Accounts | Engagements | Ledger | Testing         ^ 커밋 뒤 broadcast
   Triage   | Review      | AuditTrail               |
   |  Ecto.Multi + Repo.transact (상태 변경 + audit_event + Oban job 을 한 트랜잭션에)
   v
 Tickmark.Repo ---> PostgreSQL 16
                     도메인 테이블, audit_events (append-only 트리거), oban_jobs
 Oban (OSS)
   ingest(1): Ledger.ImportWorker
   rules(4):  Testing.RuleWorker    (실행마다 룰 수만큼 fan-out)
   llm(2):    Triage.TriageWorker -> Tickmark.AI (behaviour)
                                       +-- AI.Anthropic (Req -> Claude API)
                                       +-- AI.Fake (결정적, 키가 없을 때와 테스트)
```

| Context | 책임 |
|---|---|
| Accounts | 인증, User, Scope (`mix phx.gen.auth`) |
| Engagements | 감사 대상, 멤버와 역할 (작성자, 검토자), 권한 정책, engagement 토픽 |
| Ledger | CSV 파싱, 검증, 적재, 합성 GL 생성기 |
| Testing | 룰 behaviour와 레지스트리, 실행 fan-out, 완료 감지, finding 생성 |
| Triage | AI 입력 구성, `input_hash`, 트리아지 job, 결과 저장 |
| Review | 작성자 결론, 검토자 결정, 직무분리 |
| AuditTrail | 감사 이벤트 append와 조회. update/delete 함수가 없다 |
| AI (infra) | LLM 클라이언트 behaviour, Anthropic과 Fake 구현, 프롬프트 버전 |

### 주요 설계 결정

- **한 트랜잭션.** 상태 변경, 감사 이벤트, Oban job을 `Ecto.Multi`로 함께 커밋한다. job이 들어갔는데 기록이 없거나, 기록은 있는데 job이 없는 상태가 생기지 않는다. PubSub 방송은 커밋 뒤에만 보낸다.
- **Oban OSS만으로 fan-out과 완료 감지.** 실행 하나를 룰 수만큼 job으로 나누고, 마지막 룰이 끝난 job이 같은 트랜잭션에서 finding을 집계한다. Pro의 Batch 대신 부모 행을 먼저 `FOR UPDATE`로 잠그는 순서로 동시 마감과 교착을 막는다.
- **중복 방지는 DB 상태 전이로.** Oban unique는 조회 기반이라 경합에 약하다. 조건부 UPDATE로 실제로 상태가 바뀐 행만 job으로 넣는다.
- **AI 출력 추적.** 모든 AI 제안에 요청 모델 ID, 응답 모델, 프롬프트 버전, 입력 해시(`input_hash`)를 저장한다. 같은 입력이면 API를 다시 부르지 않는다. 적요와 거래처 같은 원문은 `untrusted_text`로 감싸 프롬프트 주입을 구분한다.
- **API 키 없이도 동작.** LLM 클라이언트를 behaviour 뒤에 두고, 키가 없으면 결정적인 Fake 구현이 전체 흐름을 돌린다. 테스트는 키를 읽지 않는다.

계약(공개 함수 시그니처, 데이터 모델, 이벤트 목록, PubSub 메시지)과 대안 비교는 [시스템 구조와 데이터 모델](docs/architecture/2026-10-17-4-시스템-구조와-데이터-모델.md)에 있다.

## 기술 스택

| 영역 | 선택 | 버전 |
|---|---|---|
| 언어/런타임 | Elixir, Erlang/OTP | 1.20.4, 29.1.2 (`.tool-versions`) |
| 웹 | Phoenix, LiveView, PubSub, Presence | 1.8.15, 1.2.12 |
| HTTP 서버 | Bandit | 1.13 |
| 데이터 | Ecto SQL, PostgreSQL | 3.14.0, 16.4 |
| 백그라운드 작업 | Oban (OSS 기능만) | 2.24.2 |
| CSV | NimbleCSV | 1.3.0 |
| LLM | Claude API (Req로 직접 호출) | Req 0.7 |
| 프런트엔드 | Tailwind, esbuild (Phoenix 기본) | |

2단계에서 검토하는 것: OpenTelemetry (관측성), Ash Framework (일부 영역), ClickHouse (대량 분개 분석), Terraform + Microsoft Azure (인프라).

## 왜 Elixir인가

지원하는 팀의 스택이 Elixir/Phoenix다. 그 위에서 이 도메인에 맞는 점을 이 코드에서 직접 쓰고 있다.

- **LiveView와 PubSub.** 화면마다 서버 프로세스가 하나씩 있고, 커밋 뒤 방송된 메시지를 받아 다시 그린다. 룰 진행률, 다른 사람의 결론 제출, 새 감사 이벤트가 별도 프런트엔드 상태 관리 없이 실시간으로 보인다.
- **프로세스 격리와 재시도.** 룰 실행과 LLM 호출은 Oban job 프로세스 안에서 돈다. 하나가 죽거나 시간을 넘겨도 다른 작업과 화면에 번지지 않고, 마지막 시도의 실패는 telemetry 핸들러가 받아 상태를 실패로 기록한다.
- **Postgres 위의 job 큐.** Oban은 job을 같은 DB에 저장한다. 그래서 상태 변경, 감사 이벤트, job 생성을 한 트랜잭션에 묶을 수 있고 별도 메시지 브로커가 필요 없다.
- **패턴 매칭과 changeset.** 오류를 `{:rate_limited, retry_after}`, `{:retryable, _}`, `{:fatal, _}` 같은 값으로 나눠 워커가 재시도, 대기(snooze), 취소를 고른다. DB 제약 위반은 Ecto changeset 오류로 바꿔 화면의 필드 오류로 보인다.

## 로컬 실행

### 준비물

- Elixir 1.20.4 / Erlang/OTP 29.1.2. 버전은 `.tool-versions`에 있다 (asdf, mise 또는 Homebrew).
- PostgreSQL 16. 개발 설정은 `localhost:5432`, 사용자 `postgres`, 비밀번호 `postgres`, DB `tickmark_dev`다 (`config/dev.exs`). 다르면 그 파일을 고친다.

### 실행

```bash
git clone https://github.com/basilry/kpmg-elixir.git
cd kpmg-elixir
mix setup              # 의존성 설치, DB 생성과 마이그레이션, 에셋 빌드
mix phx.server         # http://localhost:4000
# 또는 IEx 셸과 함께
iex -S mix phx.server
```

### 데모 순서

1. `/users/register`에서 계정 두 개(작성자용, 검토자용)를 만든다. 개발 환경의 메일은 실제로 보내지 않고 `/dev/mailbox`에서 로그인 링크를 연다.
2. 작성자 계정으로 `/engagements`에서 감사 대상을 만든다. 만든 사람이 작성자가 된다.
3. 감사 대상 상세(S2)에서 검토자 계정의 이메일을 검토자로 추가한다.
4. "GL 불러오기"(S3)의 "합성 GL 생성" 탭에서 시드를 넣고 생성한다. 기본 시드(20251231)는 전표 8,341건, 행 19,804개를 만든다. CSV 파일을 직접 올려도 된다.
5. 적재가 끝나면 S2에서 "테스트 실행"을 누른다. S4에서 룰 8종의 진행률이 실시간으로 올라가고, 끝나면 위험 전표 목록이 보인다.
6. S4 목록에서 전표를 누르면 S5에서 분개 라인, 룰 근거, 점수 계산식을 본다. AI 제안 요청, 결론 제출, 검토자 계정의 승인/반려는 개발 중이다.
7. S2의 "감사 로그"(S6)에서 지금까지의 행위를 행위자(사람, AI, 시스템)와 전표번호로 거른다. 다른 창에서 일이 생기면 "새 이벤트 N건" 단추가 나타난다.

개발 도구: `/dev/dashboard` (LiveDashboard), `/dev/mailbox` (보낸 메일 미리보기).

### 환경 변수

모두 선택이다. 없으면 기본값으로 동작한다.

| 변수 | 용도 | 기본값 |
|---|---|---|
| `ANTHROPIC_API_KEY` | 있으면 실제 Claude API로 트리아지한다. `config/runtime.exs`에서만 읽고 테스트 환경에서는 읽지 않는다 | 없음 (Fake 클라이언트) |
| `ANTHROPIC_MODEL` | 트리아지 모델 ID | `claude-opus-5-5` |
| `TICKMARK_IMPORT_DIR` | 업로드하거나 생성한 GL 파일을 두는 디렉터리 | 시스템 임시 디렉터리 아래 `tickmark_imports` |
| `PORT` | HTTP 포트 | `4000` |

키는 셸 환경 변수로만 넘긴다. `.env` 파일은 커밋하지 않는다. 운영 환경은 Phoenix 기본 변수(`DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `PHX_SERVER`)가 추가로 필요하다.

### 테스트

```bash
mix test               # 테스트 (DB 생성과 마이그레이션 포함)
mix precommit          # 커밋 전 검증: 경고 0 컴파일, 미사용 deps 정리, 포맷, 테스트
mix ecto.reset         # 개발 DB 초기화
```

테스트는 Fake AI 클라이언트와 `Req.Test`로 외부 API를 부르지 않는다. 여러 작업 트리에서 동시에 돌릴 때는 `MIX_TEST_PARTITION=<번호>`로 테스트 DB를 나눈다. 2026-10-20 기준 389개 테스트가 통과한다.

## 디렉터리 구조

```
lib/tickmark/              도메인 컨텍스트 (accounts, engagements, ledger, testing, triage, review, audit_trail, ai)
lib/tickmark/testing/rules/ 분개 테스트 룰 8종 (룰 하나에 파일 하나)
lib/tickmark_web/live/     LiveView 화면 (S1-S6)
priv/repo/migrations/      스키마, DB 제약, append-only 트리거
test/                      ExUnit, LiveView 테스트
docs/                      기획, 설계, 디자인, 도메인, 개발 기록 (색인: docs/README.md)
refs/                      Phoenix 1.8 LLM 가이드라인 원문
```

## 문서

- [docs 색인](docs/README.md): 카테고리별 전체 문서 목록
- [MVP 범위와 일정](docs/planning/2026-10-17-2-MVP-범위와-일정.md), [WBS와 마일스톤](docs/planning/2026-10-17-8-WBS와-마일스톤.md), [TASKS.md](TASKS.md) (지금 할 일)
- [시스템 구조와 데이터 모델](docs/architecture/2026-10-17-4-시스템-구조와-데이터-모델.md)
- [분개 테스트 룰과 감사 용어](docs/domain/2026-10-17-3-분개테스트-룰과-감사-용어.md)
- [디자인 시스템](docs/design/2026-10-17-5-디자인-시스템.md), [화면설계서](docs/design/2026-10-17-13-화면설계서.html)
- [개발 기록](docs/devlog/)

## 개발 방식

메인 세션(오케스트레이터)이 작업을 나누고 공유 계약(스키마, 함수 시그니처, PubSub 메시지)을 먼저 문서로 확정한 뒤, AI 팀 에이전트들이 각자 git worktree와 브랜치에서 병렬로 구현한다. 메인 세션이 diff와 테스트 출력을 직접 확인하고 하나씩 병합한다. 작업 원칙은 [AGENTS.md](AGENTS.md)에 있다.

## 진행 상황 (2026-10-20)

- M0 기반, M1 데이터 기반과 GL 적재: 완료
- M2 룰 엔진과 실시간 진행률: 기능 완료, 통합 테스트 마무리 중
- M3 AI 트리아지: 개발 중. M4 Review 컨텍스트와 감사 로그 화면(S6): 완료, S5 동작과 Presence: 개발 중
- M5 디자인 다듬기와 배포, M6 데모 GIF: 대기

세부 일정과 담당은 [WBS](docs/planning/2026-10-17-8-WBS와-마일스톤.md)를 따른다.
