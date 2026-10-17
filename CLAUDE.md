# CLAUDE.md - Tickmark

이 저장소의 작업 원칙은 AGENTS.md에 있다. Claude Code도 그대로 따른다.

@AGENTS.md

## Claude Code 전용 메모

- 팀 에이전트는 Agent 도구로 띄운다. 기본은 백그라운드 실행이고, 코드를 쓰는 워커는 `isolation: "worktree"`로 격리한다.
- 워커 브리핑에는 AGENTS.md 5.2절 3번 항목(목표, 소유 파일, 계약 문서, 검증 명령, 산출 문서 파일명)을 빠짐없이 넣는다. 코드 워커에게는 `refs/phoenix-guidelines.md`를 먼저 읽으라고 명시한다.
- 워커 보고는 그대로 믿지 않는다. 메인 세션이 diff와 검증 출력을 직접 확인한 뒤 병합한다.
