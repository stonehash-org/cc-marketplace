# AST Refactor Plugin for Claude Code

Claude Code 에이전트가 코드 리팩토링/분석 작업 시 일관성 있고 빠르게 수행할 수 있도록 만든 tree-sitter AST 기반 도구 모음입니다.

## 왜 만들었나

에이전트가 코드를 수정할 때 발생하는 문제:
- **심볼 이름 변경** 시 문자열/주석 안의 텍스트까지 바꿔버림
- **파일 이름 변경** 시 import 경로 갱신을 누락함
- **참조 추적**이 grep 기반이라 부정확함
- **영향도 파악** 없이 코드를 수정해서 사이드 이펙트 발생

이 플러그인은 tree-sitter AST 파싱으로 코드 구조를 정확히 이해하고, 에이전트가 안전하게 리팩토링할 수 있게 합니다.

## 작동 방식

1. 사용자가 자연어로 요청 (예: "userId를 accountId로 바꿔줘")
2. SKILL.md의 키워드 매칭으로 스킬 자동 트리거
3. 에이전트가 적절한 스크립트를 `--dry-run`으로 먼저 실행
4. 결과를 사용자에게 보여주고 확인 후 실행

사용자가 스크립트를 직접 실행할 필요는 없습니다. 에이전트가 Bash 도구를 통해 호출합니다.

## 요구사항

| 도구 | 설치 |
|------|------|
| tree-sitter CLI | `brew install tree-sitter-cli` |
| ripgrep | `brew install ripgrep` |
| jq | `brew install jq` |

초기 설정: `bash scripts/setup.sh` (grammar 다운로드 및 검증)

## 지원 언어

| 언어 | 확장자 |
|------|--------|
| TypeScript / JavaScript | `.ts` `.tsx` `.js` `.jsx` `.mjs` `.cjs` |
| Python | `.py` |
| Java | `.java` |
| Kotlin | `.kt` `.kts` |

`add-language.sh --lang <name>` 으로 추가 가능. 자동 감지: rust, go, ruby, c, cpp, csharp, swift, php, scala

## 스크립트 목록

### Core Refactoring - 코드 수정

| 스크립트 | 역할 | 핵심 옵션 |
|---------|------|----------|
| `find-references.sh` | 심볼 참조 검색 (정의/참조/임포트/파라미터 구분) | `--symbol` `--path` |
| `rename-symbol.sh` | 심볼 이름 변경 (문자열/주석 제외) | `--symbol` `--new` `--path` `--scope` `--start-line` `--end-line` |
| `rename-file.sh` | 파일 이름 변경 + import 자동 갱신 | `--file` `--new` `--path` |
| `rename-case.sh` | 네이밍 컨벤션 변환 (camel/snake/pascal/kebab) | `--symbol` `--to` |
| `selective-rename.sh` | 특정 라인만 선택적 이름 변경 | `--symbol` `--new` `--include-lines` `--exclude-lines` |
| `batch-rename.sh` | JSON 매핑 파일로 일괄 이름 변경 | `--map` `--path` |

### Advanced Refactoring - 구조 변경

| 스크립트 | 역할 | 핵심 옵션 |
|---------|------|----------|
| `extract-function.sh` | 코드 블록을 새 함수로 추출 | `--file` `--start-line` `--end-line` `--name` |
| `inline-variable.sh` | 변수를 값으로 교체 후 선언 제거 | `--symbol` `--file` |
| `move-symbol.sh` | 심볼을 다른 파일로 이동 + import 갱신 | `--symbol` `--from` `--to` |
| `change-signature.sh` | 함수 시그니처 변경 + 호출부 갱신 | `--symbol` `--add-param` `--remove-param` `--rename-param` |

### Analysis & Insight - 분석 (읽기 전용)

| 스크립트 | 역할 | 핵심 옵션 |
|---------|------|----------|
| `symbol-list.sh` | 파일/디렉토리의 심볼 목록 | `--path` `--type` |
| `dead-code.sh` | 데드 코드 탐지 | `--path` `--ignore-exports` |
| `unused-imports.sh` | 미사용 임포트 탐지/제거 | `--path` `--fix` |
| `complexity-report.sh` | 함수 복잡도 분석 | `--path` `--threshold` |
| `import-map.sh` | 임포트 의존성 매트릭스 + 순환 감지 | `--path` `--format table\|json\|csv` |
| `type-hierarchy.sh` | 클래스 상속 계층 구조 | `--symbol` `--path` `--direction` |
| `code-stats.sh` | 코드 통계 (언어/라인/심볼/데드코드율) | `--path` |
| `dependency-graph.sh` | 파일 의존성 그래프 | `--path` `--format mermaid\|dot\|json` |
| `diff-impact.sh` | 변경 영향도 분석 + 테스트 파일 식별 | `--commit` `--staged` |

### Safety & Workflow

| 스크립트 | 역할 | 핵심 옵션 |
|---------|------|----------|
| `validate.sh` | 문법/임포트 검증 | `--path` |
| `undo.sh` | 백업 및 되돌리기 | `--list` `--last` `--id` |
| `setup.sh` | 초기 설치 | — |
| `add-language.sh` | 새 언어 추가 | `--lang` |
| `shared-lib.sh` | 공통 라이브러리 (직접 실행 X) | — |

## 공통 옵션

모든 수정 스크립트에 적용:

| 옵션 | 설명 |
|------|------|
| `--dry-run` | 미리보기 (파일 수정 없음) |
| `--format text\|json` | 출력 형식 |
| `--git` | 변경 파일 자동 staging |
| `--git-commit MSG` | 자동 커밋 |
| `--no-config` | .refactorrc 설정 무시 |

## 설정 파일

프로젝트 루트에 `.refactorrc`:

```json
{
  "exclude": ["node_modules", "dist", "build"],
  "backup": true,
  "git_integration": true,
  "validate_after_rename": true
}
```

## 구조

```
ast-refactor/
├── .claude-plugin/plugin.json       # 플러그인 매니페스트
├── skills/ast-refactor/SKILL.md     # 에이전트 트리거 스킬
├── scripts/              (26개)     # 실행 스크립트
│   ├── shared-lib.sh               # 공통 함수 (detect_language, run_query 등)
│   ├── submit-feedback.sh          # 에이전트 피드백 제출
│   └── feedback-summary.sh         # 피드백 요약 조회
├── agent-feedbacks/                 # 에이전트 피드백 데이터 (JSONL)
└── queries/              (4 언어)   # tree-sitter 쿼리
    ├── typescript/       (6 files)  # symbols, assignment-value, block-range,
    ├── python/           (6 files)  #   call-arguments, control-flow,
    ├── java/             (6 files)  #   inheritance
    └── kotlin/           (6 files)
```

## 에이전트 피드백

에이전트가 스크립트 사용 후 자동으로 `agent-feedbacks/` 에 결과를 기록합니다.
이 데이터를 통해 어떤 스크립트가 자주 실패하는지, 어떤 옵션이 혼란을 주는지 파악하고 개선합니다.

```bash
# 피드백 요약 조회
bash scripts/feedback-summary.sh
bash scripts/feedback-summary.sh --days 7 --format json
```
