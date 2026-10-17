# Engagements 컨텍스트와 S1, S2 화면

- 작성일: 2026-10-17
- 작성: 워커 A (브랜치 `feature/engagements`, 기준 커밋 `92fa9e2`)
- 관련 문서: [시스템 구조와 데이터 모델](../architecture/2026-10-17-4-시스템-구조와-데이터-모델.md), [디자인 시스템](../design/2026-10-17-5-디자인-시스템.md)

## 목표

메인 세션이 먼저 만든 접근 제어 함수(`fetch_role/2`, `authorize/3`, `topic/1`, `subscribe/2`, `broadcast/2`) 위에 Engagements 컨텍스트의 나머지 공개 함수를 붙인다. 감사 대상 목록(S1)과 상세(S2) 화면을 만든다. 완료 조건은 `MIX_TEST_PARTITION=_a mix precommit` 통과(경고 0, 포맷, 전체 테스트)다.

## 한 일

- `lib/tickmark/engagements.ex`에 공개 함수 6개를 추가했다. 기존 5개는 고치지 않았다.
  - `list_engagements/1`: 내가 멤버인 감사 대상만, 최신순.
  - `get_engagement!/2`: 비멤버, 없는 id, UUID 형식이 아닌 id 모두 `Ecto.NoResultsError`.
  - `create_engagement/2`: Multi 하나로 감사 대상, 생성자의 preparer 멤버, `engagement.created` 감사 이벤트를 한 트랜잭션에 넣는다.
  - `change_engagement/2`: 폼용 changeset.
  - `add_member/4`: 생성자만(`:manage_members`). 모르는 이메일은 `{:error, :user_not_found}`, 이미 멤버면 changeset 오류. 멤버 insert와 `engagement.member_added` 감사 이벤트를 Multi 하나로 넣는다.
  - `list_members/2`: `:view` 권한 확인, user preload, 추가된 순서(`inserted_at`, `id`).
- `test/support/fixtures/engagements_fixtures.ex`: 컨텍스트 함수를 그대로 거치는 fixture. 생성자 멤버와 감사 이벤트가 앱과 같은 방식으로 만들어진다.
- S1 `EngagementLive.Index`: 목록은 stream으로 그린다. `:new`에서는 같은 화면 위쪽에 생성 패널을 열고, 저장에 성공하면 S2로 `push_navigate` 한다.
- S2 `EngagementLive.Show`: 개요(결산일, 수행중요성 `225,000,000원`), 멤버 목록, 생성자에게만 보이는 멤버 추가 폼, GL 적재와 테스트 실행의 빈 섹션을 그린다. GL 업로드와 감사 로그 링크는 작성자에게만 보인다. connected mount에서 감사 대상 토픽을 구독하고, 4가지 메시지(`:import_updated`, `:test_run_updated`, `:finding_updated`, `:audit_appended`)는 받기만 하고 화면을 바꾸지 않는다.
- `engagement_live/components.ex`: 역할 라벨(작성자, 검토자), `FY2025` 표기, 원화 천 단위 구분, 역할 배지.
- 테스트: 컨텍스트 테스트 `test/tickmark/engagements_test.exs`와 LiveView 테스트 13개 `test/tickmark_web/live/engagement_live_test.exs`.

검증 결과 (실제 출력):

```
$ MIX_TEST_PARTITION=_a mix test test/tickmark/engagements_test.exs test/tickmark/engagements
Result: 30 passed

$ MIX_TEST_PARTITION=_a mix test test/tickmark_web/live/engagement_live_test.exs
Finished in 0.3 seconds (0.3s async, 0.00s sync)
Result: 13 passed

$ MIX_TEST_PARTITION=_a mix precommit
Finished in 0.3 seconds (0.3s async, 0.04s sync)
Result: 179 passed
```

`mix precommit`의 `deps.unlock --unused`는 `mix.lock`을 바꾸지 않았다.

## 결정과 트레이드오프

| 주제 | 결정 | 검토한 대안 | 이유 |
|---|---|---|---|
| 목록에서 "내 역할" 표시 | 내 멤버 행만 join해서 `members`에 preload(쿼리 1번) | 감사 대상마다 `fetch_role/2` 호출 / 스키마에 virtual 필드 추가 | N+1을 피한다. 스키마 변경은 이번 범위 밖이다. 대신 이렇게 읽은 `members`에는 내 행 하나만 들어 있다는 점을 함수 문서에 적었다 |
| 형식이 틀린 id | `Ecto.UUID.cast/1`로 먼저 검사하고 `Ecto.NoResultsError`를 직접 raise | 그대로 쿼리에 넣기 | 그대로 넣으면 `Ecto.Query.CastError`가 나고 phoenix_ecto가 400으로 바꾼다(`deps/phoenix_ecto/lib/phoenix_ecto/plug.ex`). 존재하지 않는 감사 대상과 같은 404로 맞춘다 |
| `created_by_id` | scope에서만 가져오고 attrs는 무시 | changeset의 cast에 포함 | 폼에서 다른 사람을 생성자로 넣을 수 없어야 한다. 테스트로 막았다 |
| 비멤버의 `list_members/2` | 빈 리스트 | `{:error, :forbidden}` / raise | 계약 시그니처(`[Member.t()]`)를 지키고, 감사 대상이 있는지 없는지도 드러내지 않는다 |
| `add_member/4`의 역할 인자 | atom과 문자열 둘 다 받음(Ecto.Enum이 캐스팅) | 화면에서 atom으로 바꿔 넘기기 | 폼 값이 문자열이라 화면에서 `String.to_existing_atom/1`을 부를 일이 없어진다. 잘못된 값은 changeset의 "is invalid"로 막힌다 |
| 권한 확인 순서 | 권한 먼저, 이메일 조회는 그다음 | 이메일 먼저 | 비멤버가 이메일을 넣어보며 가입 여부를 알아내지 못하게 한다 |
| 화면의 권한 표시 | 버튼만 숨기고 컨텍스트에서 다시 검사 | 화면에서만 검사 | 손으로 만든 `add_member` 이벤트도 막혀야 한다. `render_hook` 테스트로 확인했다 |
| 검증 메시지 언어 | changeset 기본(영어) 메시지를 그대로 둠, 화면 고유 메시지만 한글 | 화면에서 메시지를 한글로 바꿔치기 | Gettext 로케일이 `en`만 있다(`priv/gettext`). 한 화면만 한글로 바꾸면 인증 화면과 달라진다. ko 로케일 추가는 config 변경이라 메인 세션에 요청한다 |
| 표기 helper 위치 | `engagement_live/components.ex` | 공용 `TickmarkWeb.Format` 모듈 | 소유 범위가 `engagement_live/*`다. 공용 모듈은 다른 화면이 생길 때 메인 세션이 옮긴다 |
| 원화 표기 | 소수점 아래가 0이면 생략, 아니면 2자리 | 항상 정수로 반올림 | 원 단위가 아닌 이상 데이터가 들어와도 화면에서 숨겨지지 않게 한다 |

## 막힌 점과 해결

- 계약 문서는 `Engagement.t()`, `Member.t()`를 반환 타입으로 쓰지만 스키마 모듈에 `@type t`가 없다. 기존 스키마 모듈 모두 같은 상태라서 이번에는 추가하지 않고 보고서에 남겼다.
- 생성 실패 시 트랜잭션 원자성: 잘못된 attrs는 Multi의 첫 단계에서 멈추므로, 테스트는 세 테이블 모두 0행인지만 본다. 뒤 단계 실패 시 앞 단계가 롤백되는 것은 기존 `audit_trail_test`의 "rolls back with the rest of the Multi"가 이미 다룬다.
- LiveView 테스트에서 비멤버 접근은 `live/2`가 처음 보내는 HTTP GET(disconnected mount)에서 예외가 나므로, `assert_raise Ecto.NoResultsError, fn -> live(conn, path) end`로 잡힌다.
- 금액 뒤의 `원`은 `<span>` 바로 뒤에 공백 없이 붙여서, `has_element?(view, "#engagement-overview", "225,000,000원")`처럼 텍스트로 확인할 수 있게 했다.

## Elixir 학습 포인트

- **Ecto.Multi**: 여러 쓰기를 이름 붙인 단계로 쌓아 두고 `Repo.transact/1`로 한 번에 실행한다. 앞 단계 결과가 필요한 단계는 함수(`fn %{engagement: e} -> ... end`)로 넘긴다. 실패하면 `{:error, 실패한_단계, 값, 그때까지의_결과}`가 와서 어느 단계가 실패했는지 pattern matching으로 고를 수 있다.
- **changeset과 DB 제약**: 중복 멤버는 `unique_constraint([:engagement_id, :user_id], error_key: :user_id)`가 DB의 unique 위반을 changeset 오류로 바꿔준다. 미리 SELECT로 확인하지 않아도 되고, 동시에 두 요청이 와도 DB가 하나만 통과시킨다.
- **`with`**: 권한 확인, 사용자 조회를 순서대로 엮고, 중간에 `{:error, ...}`가 나오면 그 값을 그대로 돌려준다. 오류마다 `case`를 중첩하지 않아도 된다.
- **LiveView 생명주기**: `mount/3`은 HTTP 요청(정적 렌더)과 websocket 연결에서 두 번 불린다. 구독은 메시지를 받을 프로세스가 있는 두 번째에만 하도록 `connected?/1`로 나눴다. `handle_params/3`은 `patch`로 `/engagements`와 `/engagements/new`를 오갈 때마다 불려서, 목록을 다시 읽지 않고 패널만 열고 닫는다.
- **streams**: 목록 항목을 서버 메모리에 들고 있지 않고 클라이언트 DOM에만 둔다. 새 멤버는 `stream_insert/3`로 한 행만 보낸다. 빈 상태는 stream 컨테이너 안에 `hidden only:table-row` 행을 두어 CSS로 처리한다.
- **handle_info**: PubSub 메시지는 LiveView 프로세스의 메일박스로 들어오고 `handle_info/2`가 받는다. 처리하지 않는 메시지 형태가 오면 FunctionClauseError로 프로세스가 죽으므로, 계약의 4가지 메시지 모두 절을 만들어 두었다.
- **폼**: changeset이 없는 멤버 추가 폼은 `to_form(params, as: :member, errors: [email: {"메시지", []}])`로 만든다. 코어 `<.input>`은 `used_input?/1`이 참인 필드에만 오류를 보여준다.

## 다음 할 일

- 메인 세션: Ledger 병합 뒤 S2의 GL 적재 목록(`Ledger.list_imports/2`)과 `:import_updated` 처리 연결.
- 메인 세션 검토 요청: Gettext ko 로케일, `tk-table`과 `text-muted` 디자인 토큰을 `app.css`에 추가, `Layouts.app`의 `max-w-2xl`이 표 화면에는 좁음.
- S1의 "최근 테스트", "검토 큐" 열은 TestRun 컨텍스트가 생긴 뒤 추가.

## 관련 커밋

- `2c53fa2` feat(engagements): 감사 대상 생성, 조회, 멤버 관리 함수 추가
- `7caade2` feat(engagement-live): 감사 대상 목록(S1)과 상세(S2) 화면 구현
- 이 문서 커밋: docs(devlog): Engagements 컨텍스트 작업 기록
