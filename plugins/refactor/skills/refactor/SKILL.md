---
name: refactor
description: Use when the user asks to rename, refactor, analyze code structure, find references, detect dead code, check complexity, move symbols, extract functions, inline variables, change function signatures, validate syntax, view dependency graphs, or add a new language. Triggers on keywords like "rename", "refactor", "변수명 변경", "파일명 변경", "참조 찾기", "find references", "리팩토링", "이름 변경", "symbol rename", "dead code", "unused imports", "complexity", "dependency graph", "import map", "type hierarchy", "extract function", "inline variable", "move symbol", "change signature", "validate", "코드 분석", "사용하지 않는 코드", "함수 추출", "심볼 이동", "코드 통계", "영향도 분석", "add language".
---

# Refactor Plugin

tree-sitter AST 기반 리팩토링/분석 도구. 문자열·주석을 제외하고 코드 심볼만 정확히 처리한다.

**스크립트 경로**: `~/.claude/plugins/local/refactor/scripts/`
**지원 언어**: TypeScript/JavaScript, Python, Java, Kotlin

## 핵심 규칙

1. **수정 작업은 반드시 `--dry-run` 먼저** → 결과를 사용자에게 보여주고 → 확인 후 실행
2. **수정 후 반드시 `validate.sh` 실행** → 문법/import 깨짐 확인
3. **`--format json` 사용** → 결과를 파싱해서 후속 판단에 활용

## 어떤 스크립트를 쓸지 결정하기

### "이름 바꿔줘" 요청이 들어오면:

```
단일 심볼 이름 변경?
├─ 프로젝트 전체 → rename-symbol.sh --scope project
├─ 특정 파일만 → rename-symbol.sh --scope file --file FILE
├─ 특정 라인 범위만 → rename-symbol.sh --file FILE --start-line N --end-line M
└─ 일부 참조만 골라서 → selective-rename.sh --include-lines "N,M"

여러 심볼 한번에?
└─ batch-rename.sh --map rename-map.json

네이밍 컨벤션 변환? (camelCase→snake_case 등)
└─ rename-case.sh --to snake

파일 이름 변경 + import 갱신?
└─ rename-file.sh --file OLD --new NEW
```

### "리팩토링 해줘" 요청이 들어오면:

```
코드 블록을 함수로 추출?
└─ extract-function.sh --file FILE --start-line N --end-line M --name FUNC

변수를 값으로 대체하고 선언 제거?
└─ inline-variable.sh --symbol VAR --file FILE

심볼을 다른 파일로 이동?
└─ move-symbol.sh --symbol NAME --from FILE --to FILE

함수 파라미터 추가/제거/이름변경?
└─ change-signature.sh --symbol FUNC --add-param "name:type=default"
```

### "분석해줘" 요청이 들어오면:

```
심볼이 어디서 쓰이는지? → find-references.sh --symbol NAME --path DIR
전체 심볼 목록?         → symbol-list.sh --path DIR
데드 코드?              → dead-code.sh --path DIR
미사용 import?          → unused-imports.sh --path DIR
함수 복잡도?            → complexity-report.sh --path DIR --threshold 10
파일 의존성 그래프?      → dependency-graph.sh --path DIR --format mermaid
import 매트릭스?        → import-map.sh --path DIR --format table
클래스 상속 계층?        → type-hierarchy.sh --symbol CLASS --path DIR
코드 통계?              → code-stats.sh --path DIR
변경 영향도?            → diff-impact.sh --commit HEAD~1..HEAD
```

## 실행 템플릿 (복사해서 바로 실행)

> `S=~/.claude/plugins/local/refactor/scripts` 로 축약. 실제로는 전체 경로 사용.

### 심볼 참조 찾기

```bash
bash $S/find-references.sh --symbol SYMBOL_NAME --path ./src --format json
```

### 심볼 이름 변경

```bash
# 1단계: dry-run
bash $S/rename-symbol.sh --symbol OLD_NAME --new NEW_NAME --path ./src --dry-run --format json

# 2단계: 사용자 확인 후 실행
bash $S/rename-symbol.sh --symbol OLD_NAME --new NEW_NAME --path ./src --format json

# 3단계: 검증
bash $S/validate.sh --path ./src --format json
```

### 파일 이름 변경

```bash
# 1단계: dry-run
bash $S/rename-file.sh --file src/old-name.ts --new src/new-name.ts --dry-run --format json

# 2단계: 실행
bash $S/rename-file.sh --file src/old-name.ts --new src/new-name.ts --format json

# 3단계: 검증
bash $S/validate.sh --path ./src --format json
```

### 네이밍 컨벤션 변환

```bash
bash $S/rename-case.sh --symbol camelCaseName --to snake --path ./src --dry-run
```

대상: `camel`, `snake`, `pascal`, `kebab`

### 선택적 이름 변경

```bash
# 1단계: 참조 목록 확인
bash $S/selective-rename.sh --symbol OLD --new NEW --path ./src

# 2단계: 특정 라인만 변경
bash $S/selective-rename.sh --symbol OLD --new NEW --path ./src --include-lines "12,15,20" --dry-run
```

### 일괄 이름 변경

```bash
# rename-map.json 먼저 생성:
# {"renames": [{"old": "userId", "new": "accountId"}, {"old": "getData", "new": "fetchData"}]}

bash $S/batch-rename.sh --map rename-map.json --path ./src --dry-run
```

### 함수 추출

```bash
bash $S/extract-function.sh --file src/utils.ts --start-line 10 --end-line 25 --name newFuncName --dry-run
```

### 변수 인라인

```bash
bash $S/inline-variable.sh --symbol varName --file src/api.ts --dry-run
```

### 심볼 이동

```bash
bash $S/move-symbol.sh --symbol SymbolName --from src/old.ts --to src/new.ts --path ./src --dry-run
```

### 함수 시그니처 변경

```bash
# 파라미터 추가
bash $S/change-signature.sh --symbol funcName --path ./src --add-param "timeout:number=5000" --dry-run

# 파라미터 제거
bash $S/change-signature.sh --symbol funcName --path ./src --remove-param "legacyParam" --dry-run

# 파라미터 이름 변경
bash $S/change-signature.sh --symbol funcName --path ./src --rename-param "oldParam:newParam" --dry-run

# 파라미터 순서 변경
bash $S/change-signature.sh --symbol funcName --path ./src --reorder-params "a,b,c" --dry-run
```

### 분석 (읽기 전용 — dry-run 불필요)

```bash
# 심볼 목록
bash $S/symbol-list.sh --path ./src --format json

# 데드 코드 탐지
bash $S/dead-code.sh --path ./src --format json

# 미사용 import 탐지
bash $S/unused-imports.sh --path ./src --format json
# 자동 제거: --fix 추가

# 복잡도 분석
bash $S/complexity-report.sh --path ./src --threshold 10 --format json

# 의존성 그래프
bash $S/dependency-graph.sh --path ./src --format mermaid

# import 매트릭스
bash $S/import-map.sh --path ./src --format table

# 클래스 상속
bash $S/type-hierarchy.sh --symbol ClassName --path ./src --format json

# 코드 통계
bash $S/code-stats.sh --path ./src --format json

# 변경 영향도
bash $S/diff-impact.sh --commit HEAD~1..HEAD --path ./src --format json
```

### 검증

```bash
bash $S/validate.sh --path ./src --format json
```

### 되돌리기

```bash
bash $S/undo.sh --list
bash $S/undo.sh --last
```

### git 연동

수정 스크립트에 추가 가능한 옵션:

```bash
--git                    # 변경 파일 자동 staging
--git-commit "message"   # 자동 커밋 (--git 포함)
```

## 표준 워크플로우

### 이름 변경 시

```
find-references.sh (참조 파악) → rename-symbol.sh --dry-run (미리보기) → 사용자 확인 → rename-symbol.sh (실행) → validate.sh (검증)
```

### 구조 변경 시

```
symbol-list.sh (현황 파악) → extract-function.sh / move-symbol.sh --dry-run → 사용자 확인 → 실행 → validate.sh (검증)
```

### 코드 분석 시

```
code-stats.sh (전체 통계) → dead-code.sh + unused-imports.sh (문제 탐지) → complexity-report.sh (복잡도) → 결과 종합 보고
```

## 설정 파일 (.refactorrc)

프로젝트 루트에 `.refactorrc`가 있으면 자동 로드:

```json
{
  "exclude": ["node_modules", "dist", "build"],
  "backup": true,
  "git_integration": true,
  "validate_after_rename": true
}
```

무시: `--no-config`

## 언어 추가

```bash
bash $S/add-language.sh --lang rust
```

자동 감지: rust, go, ruby, c, cpp, csharp, swift, kotlin, php, scala
