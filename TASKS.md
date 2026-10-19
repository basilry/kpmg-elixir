# TASKS.md - Tickmark

지금 할 일만 둔다. 일정, 담당, 이력의 원본은 [WBS와 마일스톤](docs/planning/2026-10-17-8-WBS와-마일스톤.md) 이다. 상태가 바뀌면 WBS 를 먼저 고치고 이 파일을 맞춘다.

- MVP: 2026-10-23 (D-3)
- 지원 마감: 2026-10-25 (D-5)

## 진행 중: 라운드 4a (M3 트리아지 + M4 검토, 감사 로그)

계약: [아키텍처 문서 12.2](docs/architecture/2026-10-17-4-시스템-구조와-데이터-모델.md) (2.1, 4.2, 5.5.1, 6, 7, 8 장). 통합 브랜치는 `feature/m2-rule-engine`.

| 워커 | WBS | 작업 | 에이전트 / 모델 | 브랜치 | 상태 |
|---|---|---|---|---|---|
| W1 | 3.2 | `Tickmark.Triage` (건별/일괄 요청, `triage_finding/1`, `mark_failed/2`), TriageWorker, FailureHandler 분기 | Claude `claude-fable-5-1` xhigh | `feature/m3-triage` | 진행 중 |
| W2 | 4.1 | `Tickmark.Review` (`submit_conclusion/3`, `decide/4`), SoD 테스트 | Codex `gpt-6-astra` xhigh | `feature/m4-review` | 진행 중 |
| W3 | 4.2 | `AuditTrail.list_events/3`, S6 AuditLive | Codex `gpt-6.1-sol` max | `feature/m4-audit-log` | 진행 중 |
| W4 | 3.3 | `Testing.get_finding!/2`, `list_rule_results/2`, S5 FindingLive 표시 | Codex `gpt-6.1-sol` max | `feature/m3-finding-show` | 진행 중 |
| W5 | 2.4, 2.6 | Runner 경유 정답 라벨 시험, S2 단추 테스트, `audit_appended` 보강, DuplicateEntry 느린 쿼리 | Codex `gpt-6.1-sol` max | `feature/m2-wrapup` | 진행 중 |

## 메인 세션 다음 할 일

- [x] 2.1 워커 A 병합 (fadb51c, 385 통과)
- [x] 라운드 4 선행 작업: `AI.model/0` (fa8a3c1), `broadcast_appended/1` 과 `:triage_requested` 무시 절 (f0769f5), 계약
- [ ] 워커 결과 검토 후 하나씩 병합, 병합마다 `mix precommit`
- [ ] 라운드 4b (W1, W2, W4 병합 뒤): S5 동작 (트리아지 요청, 결론 제출, 승인/반려), S4 AI 열과 일괄 요청 (3.4), Presence (4.3, 4.4), 통합 테스트
- [ ] S1-S6 브라우저 확인
- [ ] 라운드 4 devlog (2026-10-20-1), WBS 와 이 파일 갱신
- [x] README 초안 (WBS 6.1 당김. M6 에 데모 GIF 와 최종 상태 반영)

## 사용자 결정 대기

- PR #2 (`feature/foundation` -> `main`) 병합 승인 (WBS 1.19, M1 완료 조건)
- 배포 대상: Azure 또는 Fly.io (WBS 5.1, 10/22 전)

## 다음 라운드 (M5-M6)

- 5.1-5.4 배포, 1.19 PR 정리, 제출 자료

## Changelog

- 2026-10-19: 최초 작성 (WBS 기준). 라운드 3 배정과 메인 할 일
- 2026-10-19: B, C, D 병합, 2.5 완료, 2.6 구현 반영
- 2026-10-20: A 병합, 라운드 4 선행 작업, 라운드 4a 배정 (W1-W5)
- 2026-10-20: README 초안 (6.1) 추가
