# TASKS.md - Tickmark

지금 할 일만 둔다. 일정, 담당, 이력의 원본은 [WBS와 마일스톤](docs/planning/2026-10-17-8-WBS와-마일스톤.md) 이다. 상태가 바뀌면 WBS 를 먼저 고치고 이 파일을 맞춘다.

- MVP: 2026-10-23 (D-3)
- 지원 마감: 2026-10-25 (D-5)

## 완료: 라운드 4, 4b 선행 (W6), 라운드 5 (화면 셸, 인증 화면, 명세 문서)

기록: [라운드 4 devlog](docs/devlog/2026-10-20-1-라운드-4-계약과-통합.md), [라운드 5 devlog](docs/devlog/2026-10-20-14-라운드-5-화면-셸과-명세-문서.md). 계약: [아키텍처 문서 12.2](docs/architecture/2026-10-17-4-시스템-구조와-데이터-모델.md) (2.1, 4.2, 5.5.1, 6, 7, 8 장). 통합 브랜치는 `feature/m2-rule-engine`.

| 워커 | WBS | 작업 | 에이전트 / 모델 | 브랜치 | 상태 |
|---|---|---|---|---|---|
| W1 | 3.2 | `Tickmark.Triage` (건별/일괄 요청, `triage_finding/1`, `mark_failed/2`), TriageWorker, FailureHandler 분기 | Claude `claude-fable-5-1` xhigh | `feature/m3-triage` | 병합 (52c38c8) |
| W2 | 4.1 | `Tickmark.Review` (`submit_conclusion/3`, `decide/4`), SoD 테스트 | Codex `gpt-6-astra` xhigh | `feature/m4-review` | 병합 (cf88e39) |
| W3 | 4.2 | `AuditTrail.list_events/3`, S6 AuditLive | Codex `gpt-6.1-sol` max | `feature/m4-audit-log` | 병합 (80dc408) |
| W4 | 3.3 | `Testing.get_finding!/2`, `list_rule_results/2`, S5 FindingLive 표시 | Codex `gpt-6.1-sol` max | `feature/m3-finding-show` | 병합 (34c247e) |
| W5 | 2.4, 2.6 | Runner 경유 정답 라벨 시험, S2 단추 테스트, `audit_appended` 보강, DuplicateEntry 느린 쿼리 | Codex `gpt-6.1-sol` max | `feature/m2-wrapup` | 병합 (824b89b) |
| W6 | 4.3 (일부) | S5 결론 제출, 승인/반려 2단계, `components.ex` 분리 ([계약 12.3](docs/architecture/2026-10-17-4-시스템-구조와-데이터-모델.md)) | Codex `gpt-6.1-sol` max | `feature/m4-finding-actions` | 병합 (2718ff9) |
| F1 | 5.2 | 공통 상단 바, 디자인 토큰 (`app.css`), 홈, 404, 한글 연결 끊김 문구 ([계약 12.4](docs/architecture/2026-10-17-4-시스템-구조와-데이터-모델.md)) | Codex `gpt-6.1-sol` max (fast) | `feature/ui-shell` | 병합 (4115351) |
| F2 | 5.2 | 로그인, 회원가입, 설정 화면 한글화와 디자인, Gettext ko (검증 문구) | Codex `gpt-6.1-sol` max (fast) | `feature/ui-auth` | 병합 (1e0574d) |
| D1 | - | 요구사항 명세서, 기능 정의서 | Codex `gpt-6-astra` max (fast) | `docs/requirements-spec` | 병합 (60781a3) |
| D2 | - | API 연동 규격서 | Codex `gpt-6-astra` max (fast) | `docs/api-spec` | 병합 (164788e) |

## 메인 세션 다음 할 일

- [x] 2.1 워커 A 병합 (fadb51c, 385 통과)
- [x] 라운드 4 선행 작업: `AI.model/0` (fa8a3c1), `broadcast_appended/1` 과 `:triage_requested` 무시 절 (f0769f5), 계약
- [x] 워커 결과 검토 후 하나씩 병합, 병합마다 `mix precommit` (W1-W6, F1, F2, D1, D2)
- [x] S5 AI 제안 요청 단추 (4.3, 0f53b7a)
- [ ] 라운드 4b 나머지: S4 AI 열과 일괄 요청 (3.4), Presence 와 상단 바 아바타 (4.3, 4.4), 검토 대기열과 '다음 미판단', 통합 테스트
- [x] S2 `start_run` 이 import 의 engagement 가 현재 engagement 와 같은지 확인 (W5 발견, a6a52c0)
- [x] 테스트 간헐 타임아웃 원인 (async TRUNCATE 테스트의 잠금 대기열) 제거 (9e7dbfd)
- [x] S5 의 `Layouts.app` 에 `engagement` 연결 (f300f2f)
- [x] 브라우저 확인: 홈, 로그인, S1, S2, S4, S5 (AI 요청 포함), S6. 나온 문제 3건 수정 (8502ed7)
- [ ] S3 브라우저 확인 (이번에 따로 열지 않음)
- [x] 데모 시드 (5.3, f196012): 작성자와 검토자, 누리정밀 FY2025, 적재와 룰 실행까지
- [x] 문서 위키 `/docs` 와 상단 바 링크 (6.5, 1a2ef4b)
- [x] 라운드 4, 5 와 문서 위키 devlog (2026-10-20-1, -14, -15), WBS 와 이 파일 갱신
- [ ] D1 의 FN 과 D2 의 IF 교차 링크
- [x] 배포 준비 (5.4): release, Dockerfile, 부팅 시드 `Tickmark.Demo`, 운영 메일 안내, `render.yaml`, 로컬 prod release 확인 ([가이드](docs/planning/2026-10-25-1-배포-가이드-Render-Neon.md), [devlog](docs/devlog/2026-10-25-2-배포-준비.md))
- [x] 첫 배포 로그와 외부 접속 확인, 5.4 완료 표기 (https://tickmark-e0ki.onrender.com, [devlog](docs/devlog/2026-10-25-3-Render-첫-배포와-외부-확인.md))
- [x] `plug_crypto` 2.2.0 -> 2.2.1 (EEF-CVE-2026-105963, MEDIUM), `mix precommit` 뒤 재배포 (PR #5, 9629df7 배포 확인, [가이드](docs/planning/2026-10-25-1-배포-가이드-Render-Neon.md) 5.3절)
- [ ] LiveView 출처 확인을 요청 호스트 기준으로 (`check_origin: :conn`, `fix/liveview-check-origin`). 병합 뒤 www Origin 으로 101 확인 ([가이드](docs/planning/2026-10-25-1-배포-가이드-Render-Neon.md) 5.4절)
- [ ] 메인화면 데모 자동 로그인 (`feature/demo-auto-login`, PR #8 다음에 병합). 배포 뒤 시크릿 창에서 `/` 가 `/engagements` 로 가는지 확인 ([가이드](docs/planning/2026-10-25-1-배포-가이드-Render-Neon.md) 5.5절, [devlog](docs/devlog/2026-10-27-1-데모-자동-로그인.md))
- [x] README 초안 (WBS 6.1 당김. M6 에 데모 GIF 와 최종 상태 반영)

## 사용자 결정 대기

- 배포 대상: 10/25 Render Free + Neon Free 로 결정 (5.1 완료). 같은 날 17:53 사용자가 Render 인스턴스를 0.5c-512mb (유료) 로 바꿈
- 사용자 단계 ([가이드](docs/planning/2026-10-25-1-배포-가이드-Render-Neon.md) 4장): 10/25 모두 완료 (PR #3 병합, Neon, `mix phx.gen.secret`, Render Blueprint 값 세 개)
- 플랜 유지 여부: 0.5c-512mb 를 유지하면 `render.yaml` 의 `plan: free` 를 맞추거나 Blueprint Auto Sync 를 끈다. Free 로 돌아가면 그대로 둔다 ([가이드](docs/planning/2026-10-25-1-배포-가이드-Render-Neon.md) 5.3절)
- 커스텀 도메인: `www.tickmark.6esk.com` 은 10-27 기준 인증서가 있고 200 이지만 LiveView 가 403 이다. PR #8 병합 (사용자) 과 배포 뒤 101 을 확인하기 전에는 지원서에 onrender 주소를 쓴다. 같은 문제의 PR #7 은 닫는다 (사용자) ([가이드](docs/planning/2026-10-25-1-배포-가이드-Render-Neon.md) 5.4절)
- 남은 사용자 일: 지원서에 URL, 데모 계정 기재 (6.4). 첫 접속 지연 안내는 Free 로 돌아갈 때만 적는다

## 다음 라운드 (M5-M6)

- 6.2 데모 GIF, 6.3 공개 전 점검과 저장소 공개 전환, 6.4 제출 자료

## Changelog

- 2026-10-19: 최초 작성 (WBS 기준). 라운드 3 배정과 메인 할 일
- 2026-10-19: B, C, D 병합, 2.5 완료, 2.6 구현 반영
- 2026-10-20: A 병합, 라운드 4 선행 작업, 라운드 4a 배정 (W1-W5)
- 2026-10-20: README 초안 (6.1) 추가
- 2026-10-20: W2 병합
- 2026-10-20: W3, W4 병합
- 2026-10-20: PR #2 병합 (1.19 완료), W6 배정, 배포 조건 (무료, Vercel 선호) 반영, W5 발견 (S2 start_run engagement 확인) 추가
- 2026-10-20: 배포 검토 문서 연결, Render + Neon 제안
- 2026-10-20: W5, W1 병합
- 2026-10-20: S2 start_run 확인 완료, 라운드 5 배정 (F1, F2, D1, D2)
- 2026-10-20: W6 병합 (2718ff9, 546 통과)
- 2026-10-20: 라운드 5 병합 (F1 4115351, F2 1e0574d, D1 60781a3, D2 164788e, 563 통과), 데모 시드, S5 AI 요청 단추, 문서 위키 (1a2ef4b, 584 통과). 라운드 4b 나머지와 S3 확인을 남김
- 2026-10-25: 배포 대상 결정 (Render + Neon), 배포 준비 완료와 사용자 단계 반영 (588 통과)
- 2026-10-25: PR #3 (배포 준비까지) main 병합, README 최신화
- 2026-10-25: Render 첫 배포와 외부 접속 확인 (5.4 완료), `plug_crypto` 갱신 할 일 추가
- 2026-10-25: PR #4, #5 병합과 9629df7 재배포 확인 (`plug_crypto` 할 일 완료), 플랜 변경 (Free -> 0.5c-512mb) 반영, 플랜 유지 여부 결정 항목 추가
- 2026-10-25: d4c3733 재배포 확인, 커스텀 도메인 인증서 확인 항목과 LiveView 출처 확인 수정 할 일 추가
- 2026-10-27: 커스텀 도메인 재확인 (www 인증서 발급, LiveView 403 그대로), PR #7 닫기와 PR #8 병합을 사용자 항목으로
- 2026-10-27: 메인화면 데모 자동 로그인 항목 추가 (작성자로 로그인, 로그아웃하면 멈춤, 운영만 켬)
