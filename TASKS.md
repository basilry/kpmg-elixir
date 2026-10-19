# TASKS.md - Tickmark

지금 할 일만 둔다. 일정, 담당, 이력의 원본은 [WBS와 마일스톤](docs/planning/2026-10-17-8-WBS와-마일스톤.md) 이다. 상태가 바뀌면 WBS 를 먼저 고치고 이 파일을 맞춘다.

- MVP: 2026-10-23 (D-4)
- 지원 마감: 2026-10-25 (D-6)

## 진행 중: 라운드 3 (M2 룰 엔진 + 3.1 AI 모듈)

계약: [아키텍처 문서 12.1](docs/architecture/2026-10-17-4-시스템-구조와-데이터-모델.md). 통합 브랜치는 `feature/m2-rule-engine`.

| 워커 | WBS | 작업 | 에이전트 / 모델 | 브랜치 | 상태 |
|---|---|---|---|---|---|
| A | 2.1 | `start_test_run`, RuleWorker, 완료 감지, FailureHandler | Claude `claude-fable-5-1` xhigh | `feature/m2-testing-runner` | 진행 중 |
| B | 2.2, 2.4 | 룰 7종, 레지스트리 등록, 정답 라벨 시험 | Codex `gpt-6-astra` xhigh | `feature/m2-rules` | 병합 (ff95ad8) |
| C | 2.3 | S3 ImportLive, S4 TestRunLive, `TickmarkWeb.Format` | Codex `gpt-6.1-sol` max | `feature/m2-screens` | 병합 (af65bb3) |
| D | 3.1 | `Tickmark.AI` (Client, Anthropic, Fake, Prompts, `input_hash/1`) | Codex `gpt-6.1-sol` max | `feature/m3-ai-client` | 병합 (3706032) |

## 메인 세션 다음 할 일

- [x] 2.0 선행 작업과 계약 확정
- [ ] 워커 결과 검토 (diff 와 검증 출력 직접 확인) 후 하나씩 병합, 병합마다 `mix precommit` (B, C, D 완료. A 남음)
- [ ] 2.4 Runner 를 거친 정답 라벨 시험 (A, B 병합 뒤)
- [x] 2.5 S1 "최근 테스트", "검토 큐" 열
- [ ] 2.6 S2 실행 목록, "테스트 실행" 단추, stat_row (구현 완료. 단추 클릭 테스트와 브라우저 확인은 A 병합 뒤)
- [ ] 라운드 3 devlog, WBS 와 이 파일 갱신 (devlog -6 작성. A 병합 뒤 마무리)

## 사용자 결정 대기

- PR #2 (`feature/foundation` -> `main`) 병합 승인 (WBS 1.19, M1 완료 조건)
- 배포 대상: Azure 또는 Fly.io (WBS 5.1, 10/22 전)

## 다음 라운드 (M3-M4)

- 3.2 Triage 컨텍스트와 TriageWorker, 3.3 FindingLive, 3.4 Fake 전체 흐름 확인
- 4.1 Review 와 SoD, 4.2 AuditLive, 4.3 Presence 와 결론/리뷰 UI, 4.4 통합
- 계약에 먼저 넣을 것: 화면설계서 C-08, C-09 (M3), C-11, C-13 (M4)

## Changelog

- 2026-10-19: 최초 작성 (WBS 기준). 라운드 3 배정과 메인 할 일
- 2026-10-19: B, C, D 병합, 2.5 완료, 2.6 구현 반영
