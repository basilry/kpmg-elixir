# AGENTS.md - Tickmark

이 저장소에서 일하는 모든 에이전트(메인 세션, 팀 에이전트)와 사람이 따르는 작업 원칙이다.
사용자의 직접 지시가 이 파일보다 우선하고, 이 파일은 그 외 모든 기본 동작보다 우선한다.

## 1. 프로젝트 개요

- **Tickmark**: 감사인과 AI 에이전트가 함께 일하는 감사 Work OS의 축소판. 첫 대상 업무는 분개 테스트(Journal Entry Testing).
- **목적**: 삼정KPMG Audit Innovation Software Engineer 지원 포트폴리오. Elixir를 처음 배우면서 만드는 과정 자체가 산출물이다.
- **제품 원칙**: AI는 제안하고, 판단과 서명은 사람이 한다. 모든 행위는 append-only 감사 로그에 남는다.
- **데이터 원칙**: 합성 데이터만 쓴다. 실제 고객/회사 데이터는 저장소에 절대 넣지 않는다.
- **일정**: MVP 2026-10-23, 지원 마감 2026-10-25. 세부는 `docs/planning/` 참조.

## 2. 기술 스택

| 영역 | 선택 | 단계 |
|---|---|---|
| 언어/런타임 | Elixir, Erlang/OTP (Homebrew) | MVP |
| 웹 | Phoenix 1.8, LiveView, PubSub, Presence | MVP |
| 데이터 | Ecto, PostgreSQL 16 (로컬 Postgres.app) | MVP |
| 백그라운드 작업 | Oban (OSS 기능만 사용, Pro 기능 금지) | MVP |
| LLM | Claude API (Req로 직접 호출, behaviour 뒤에 숨기고 테스트는 fake 사용) | MVP |
| 관측성 | OpenTelemetry | 2단계 |
| 도메인 프레임워크 | Ash Framework (일부 영역 실험) | 2단계 |
| 분석 | ClickHouse (대량 분개 분석) | 2단계 |
| 인프라 | Terraform + Microsoft Azure | 2단계 |

정확한 버전과 실행 명령은 9장(스캐폴딩 후 갱신)에 둔다.

## 3. 문서화 원칙

### 3.1 개발 과정 기록 (devlog)

- 의미 있는 작업 단위(기능 완성, 설계 결정, 문제 해결, 방향 전환, 병렬 라운드 종료)마다 `docs/devlog/`에 기록을 남긴다.
- 작업한 날에는 최소 1건을 남긴다.
- 기록 항목: 목표, 한 일, 결정과 트레이드오프(검토한 대안 포함), 막힌 점과 해결, Elixir 학습 포인트, 다음 할 일, 관련 커밋.
- 추측으로 채우지 않는다. 실행 결과는 실제 출력 기준으로 적는다.

### 3.2 파일명 규칙

```
{YYYY-MM-DD}-{시퀀스}-{제목}.md
예) 2026-10-17-1-테스트.md
```

- **날짜**: 문서를 처음 만든 날(KST).
- **시퀀스**: 그 날짜에 `docs/` 전체에서 만든 순서. 1부터 시작하며 카테고리별로 따로 세지 않는다. 날짜+시퀀스만으로 전체 문서가 시간순으로 유일하게 정렬된다.
- **제목**: 한글 허용. 공백은 하이픈(-)으로 바꾸고 `/ : ? * " < > |`는 쓰지 않는다.
- **다음 시퀀스 확인**:
  ```bash
  find docs -name "$(date +%F)-*.md" | sed -E 's#.*/[0-9]{4}-[0-9]{2}-[0-9]{2}-([0-9]+)-.*#\1#' | sort -n | tail -1
  ```
- **예외**: `docs/README.md`(색인), 루트의 `AGENTS.md`, `CLAUDE.md`, `README.md`, `TASKS.md`(지금 할 일 목록. 원본은 WBS 문서이고 Changelog 를 둔다).
- **갱신**: 계속 살아있는 문서(데이터 모델, 디자인 시스템 등)는 같은 파일을 고치고 문서 맨 아래 `## Changelog`에 날짜와 변경 요약을 남긴다. 파일명은 바꾸지 않는다. 내용이 근본적으로 바뀌면 새 문서를 만들고, 기존 문서 맨 위에 `> 대체됨: [새 문서](상대경로)`를 적는다.
- 문서 간 링크는 상대 경로로 건다.

### 3.3 docs 폴더 구조

```
docs/
  README.md      전체 색인 (카테고리별 문서 목록, 최신 문서 표시)
  devlog/        개발 과정 기록 (작업 일지, 학습 노트, 회고)
  planning/      기획 (요구사항, MVP 범위, 일정, 로드맵)
  architecture/  설계 (시스템 구조, 데이터 모델, 모듈 계약, ADR)
  design/        디자인 (디자인 시스템, 화면 설계, UI 흐름)
  domain/        감사/회계 도메인 (분개 테스트 룰, 용어집, 합성 데이터 명세)
```

- 설계, 기획, 디자인 관련 문서는 전부 `docs/` 아래 해당 카테고리에 둔다. 코드 디렉터리에 설계 문서를 흩어놓지 않는다.
- 새 문서를 만들면 `docs/README.md` 색인에 한 줄을 추가한다.
- 새 카테고리는 메인 세션만 만들고, 만들 때 이 절과 `docs/README.md`를 함께 갱신한다.

## 4. Git과 커밋

- 형식은 Conventional Commits를 따르되 **설명과 본문은 한글**로 쓴다. type과 scope는 영어.
  ```
  feat(ingest): 분개 CSV 대량 적재 구현

  insert_all로 묶어서 넣어 10만 건 적재 시간을 줄였다.
  ```
- type: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `style`.
- 한 커밋에는 하나의 논리적 변경만 담는다. `git add .` 대신 파일을 명시해 스테이징한다.
- 커밋 전에 검증 명령(9장의 `mix precommit`)을 통과시킨다. `--no-verify`는 쓰지 않는다.
- `main`은 통합 브랜치다. 기능 작업은 `feature/`, `fix/`, `refactor/`, `docs/` 브랜치에서 하고 메인 세션이 `main`에 병합한다.
- AI가 작성에 참여한 커밋에는 `Co-Authored-By` 트레일러를 남긴다.

## 5. 병렬 개발과 오케스트레이션

### 5.1 역할

- **메인 세션(오케스트레이터)**: 사용자와 대화하는 세션. 작업 분해, 공유 계약 확정, 에이전트 브리핑, 결과 검토, 병합, 통합 검증, devlog 작성, 커밋을 맡는다. 오케스트레이션을 하면서 직접 개발도 한다.
- **팀 에이전트(워커)**: 메인 세션이 배정한 범위만 구현한다. 사용자와 직접 소통하지 않고, 막히면 메인 세션에 보고한다.

### 5.2 라운드 진행 순서

1. **분해**: 작업을 독립 단위로 나눈다. 의존 관계가 있으면 순차, 없으면 병렬로 진행한다.
2. **계약 먼저**: 병렬 시작 전에 메인 세션이 공유 계약을 확정하고 `docs/architecture/`에 적는다. 계약에는 Ecto 스키마와 마이그레이션, context 공개 함수 시그니처, PubSub 토픽과 메시지 형태, Oban 큐 이름, 필요한 의존성 추가가 포함된다.
3. **브리핑**: 각 워커에게 다음을 명시한다.
   - 목표와 완료 조건
   - 소유 파일/디렉터리 (이 밖은 수정 금지)
   - 참조할 계약 문서
   - 검증 명령
   - 산출 문서 파일명 (시퀀스 충돌을 막기 위해 메인 세션이 미리 배정)
4. **격리**: 코드를 쓰는 워커는 각자 git worktree와 브랜치에서 작업하고 그 브랜치에 커밋한다. 문서만 쓰는 워커는 파일이 겹치지 않으면 같은 체크아웃에서 작업하되 커밋하지 않고, 메인 세션이 커밋한다.
5. **보고**: 워커는 완료 시 다음을 보고한다.
   - 변경 파일
   - 핵심 결정과 이유
   - 검증 결과 (실제 출력)
   - 남은 이슈
   - 계약 변경 요청
6. **통합**: 메인 세션이 브랜치를 하나씩 `main`에 병합하고, 병합할 때마다 검증 명령을 돌린다. 충돌은 메인 세션이 해결한다.
7. **기록**: 라운드가 끝나면 devlog에 남긴다. 누가 무엇을 했는지, 무엇이 충돌했고 어떻게 풀었는지를 적는다.

### 5.3 공유 파일 (메인 세션 소유, 워커 수정 금지)

`mix.exs`, `mix.lock`, `config/*`, `lib/tickmark/application.ex`, `lib/tickmark_web/router.ex`, `priv/repo/migrations/*`, `AGENTS.md`, `CLAUDE.md`, `refs/*`, `docs/README.md`

- 워커가 이 파일을 바꿔야 하면 보고서에 "변경 요청"으로 남긴다.
- 이유: 마이그레이션 타임스탬프 순서, 의존성 lock, 라우터와 슈퍼비전 트리는 병렬로 고치면 거의 항상 충돌한다.

### 5.4 병렬로 하지 않는 경우

- 같은 파일을 건드리는 작업
- 앞 작업의 결과(스키마, 함수 시그니처 등)가 있어야 시작할 수 있는 작업
- 계약이 아직 정해지지 않은 작업

한 라운드의 워커는 최대 3~4개로 둔다. 메인 세션의 검토 능력이 병목이기 때문이다.

## 6. 코딩 규칙 (Elixir)

- **필독**: Elixir/Phoenix 코드를 쓰거나 고치기 전에 [refs/phoenix-guidelines.md](refs/phoenix-guidelines.md)를 반드시 읽는다. `mix phx.new`(1.8)가 만든 LLM용 가이드라인 원문이다. 매 턴 불러오지 않도록 이 파일에 합치지 않고 따로 두었다. `mix phx.gen.*` 생성기가 AGENTS.md에 가이드라인을 주입하면, 메인 세션이 그 블록을 refs 파일로 옮기고 AGENTS.md는 원래대로 되돌린다.
- **파일명**: Elixir 관례대로 snake_case를 쓴다 (`lib/tickmark/ledger/journal_entry.ex`). 하이픈 파일명 규칙은 Elixir 코드에 적용하지 않고, 문서는 3.2절을 따른다.
- **경계**: Phoenix context로 도메인 경계를 나눈다. context 이름과 공개 함수는 `docs/architecture/` 계약을 따른다.
- **테스트**: 새 기능에는 ExUnit 테스트를 함께 쓴다. LiveView는 `Phoenix.LiveViewTest`로 검증한다.
- **품질**: `mix format`을 지키고 컴파일 경고는 0개로 유지한다. `IO.inspect`, `dbg`는 커밋 전에 지운다.
- **시크릿**: `ANTHROPIC_API_KEY` 등은 환경 변수로만 다루고 `config/runtime.exs`에서 읽는다. `.env`는 커밋하지 않는다.
- **감사 로그**: `audit_events`는 append-only다. 애플리케이션 코드에서 UPDATE/DELETE를 하지 않는다.
- **AI 출력 추적**: AI 판단을 저장할 때 모델 ID, 프롬프트 버전, 입력 해시를 함께 저장한다.
- **외부 API 키 없이도 동작**: LLM 클라이언트는 behaviour로 추상화하고, 키가 없으면 fake 구현으로 데모와 테스트가 돌아가게 한다.

## 7. 학습 우선 원칙

사용자는 면접(라이브 코딩 포함)에서 이 코드를 직접 설명해야 한다.

- 영리한 코드보다 읽히는 코드를 쓴다. 매크로와 메타프로그래밍은 최소화한다.
- Elixir 고유 개념(pattern matching, 프로세스와 OTP, Ecto changeset, LiveView 생명주기, Oban job)을 처음 쓰는 곳에서는 왜 그렇게 했는지 보고서나 devlog의 "학습 포인트"에 남긴다.
- 사용자가 이해하지 못한 코드는 완료로 치지 않는다.

## 8. 보안

- 시크릿, 토큰, 시스템 절대 경로를 코드와 문서에 넣지 않는다.
- 사용자 입력(CSV 업로드 포함)은 검증한다. 파일 크기와 행 수 제한, 컬럼 스키마 검증을 둔다.
- SQL은 Ecto 쿼리와 파라미터 바인딩만 쓴다. 문자열 보간 SQL은 금지한다.
- 사용자에게 보이는 에러 메시지에 내부 구현을 노출하지 않는다.

## 9. 버전과 명령어

| 항목 | 버전 | 비고 |
|---|---|---|
| Elixir | 1.20.4 | Homebrew, `.tool-versions`에 기록 |
| Erlang/OTP | 29.1.2 | Homebrew |
| Phoenix | 1.8.15 | `mix phx.new tickmark --binary-id`로 생성 |
| Phoenix LiveView | 1.2.12 | `mix.lock` 기준 |
| Ecto SQL | 3.14.0 | `mix.lock` 기준 |
| PostgreSQL | 16.4 | 로컬 Postgres.app, `localhost:5432`, 사용자 `postgres` |

```bash
mix setup          # 의존성 설치, DB 생성/마이그레이션/시드, 에셋 빌드
mix phx.server     # 개발 서버 (http://localhost:4000)
iex -S mix phx.server  # IEx 셸과 함께 실행
mix test           # 테스트
mix precommit      # 커밋 전 검증: 경고 0 컴파일, 미사용 deps 정리, 포맷, 테스트
mix ecto.reset     # DB 초기화
```

의존성 버전이 바뀌면 메인 세션이 이 표를 갱신한다.
