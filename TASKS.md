# TASKS.md - Tickmark

지금 할 일만 둔다. 일정, 담당, 이력의 원본은 [WBS와 마일스톤](docs/planning/2026-10-17-8-WBS와-마일스톤.md) 이다. 상태가 바뀌면 WBS 를 먼저 고치고 이 파일을 맞춘다.

- MVP: 2026-10-23 (D-3)
- 지원 마감: 2026-10-25 (D-5)

## 진행 중: 라운드 4a (M3 트리아지 + M4 검토, 감사 로그) + 4b 선행 (W6)

계약: [아키텍처 문서 12.2](docs/architecture/2026-10-17-4-시스템-구조와-데이터-모델.md) (2.1, 4.2, 5.5.1, 6, 7, 8 장). 통합 브랜치는 `feature/m2-rule-engine`.

| 워커 | WBS | 작업 | 에이전트 / 모델 | 브랜치 | 상태 |
|---|---|---|---|---|---|
| W1 | 3.2 | `Tickmark.Triage` (건별/일괄 요청, `triage_finding/1`, `mark_failed/2`), TriageWorker, FailureHandler 분기 | Claude `claude-fable-5-1` xhigh | `feature/m3-triage` | 병합 (52c38c8) |
| W2 | 4.1 | `Tickmark.Review` (`submit_conclusion/3`, `decide/4`), SoD 테스트 | Codex `gpt-6-astra` xhigh | `feature/m4-review` | 병합 (cf88e39) |
| W3 | 4.2 | `AuditTrail.list_events/3`, S6 AuditLive | Codex `gpt-6.1-sol` max | `feature/m4-audit-log` | 병합 (80dc408) |
| W4 | 3.3 | `Testing.get_finding!/2`, `list_rule_results/2`, S5 FindingLive 표시 | Codex `gpt-6.1-sol` max | `feature/m3-finding-show` | 병합 (34c247e) |
| W5 | 2.4, 2.6 | Runner 경유 정답 라벨 시험, S2 단추 테스트, `audit_appended` 보강, DuplicateEntry 느린 쿼리 | Codex `gpt-6.1-sol` max | `feature/m2-wrapup` | 병합 (824b89b) |
| W6 | 4.3 (일부) | S5 결론 제출, 승인/반려 2단계, `components.ex` 분리 ([계약 12.3](docs/architecture/2026-10-17-4-시스템-구조와-데이터-모델.md)) | Codex `gpt-6.1-sol` max | `feature/m4-finding-actions` | 진행 중 |

## 메인 세션 다음 할 일

- [x] 2.1 워커 A 병합 (fadb51c, 385 통과)
- [x] 라운드 4 선행 작업: `AI.model/0` (fa8a3c1), `broadcast_appended/1` 과 `:triage_requested` 무시 절 (f0769f5), 계약
- [ ] 워커 결과 검토 후 하나씩 병합, 병합마다 `mix precommit`
- [ ] 라운드 4b (W1 병합으로 시작 가능): S5 AI 분석 요청 단추, S4 AI 열과 일괄 요청 (3.4), Presence 와 상단 바 (4.3, 4.4), 검토 대기열과 '다음 미판단', 통합 테스트. S5 결론 제출과 승인/반려, `components.ex` 분리는 W6
- [ ] S2 `start_run` 이 import 의 engagement 가 현재 engagement 와 같은지 확인 (W5 발견, W5 병합 뒤 `engagement_live/show.ex`)
- [ ] S1-S6 브라우저 확인
- [ ] 라운드 4 devlog (2026-10-20-1), WBS 와 이 파일 갱신
- [x] README 초안 (WBS 6.1 당김. M6 에 데모 GIF 와 최종 상태 반영)

## 사용자 결정 대기

- 배포 대상 (WBS 5.1, 10/22 전): [검토](docs/planning/2026-10-20-8-배포-대상-검토.md) 결과 Render Free (앱) + Neon Free (DB) 제안. Vercel 은 LiveView 연결 5분 제한, Oban 정지 문제로 정적 소개 페이지에만. 결정되면 사용자가 계정을 만든다

## 다음 라운드 (M5-M6)

- 5.1-5.4 배포, 제출 자료

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
