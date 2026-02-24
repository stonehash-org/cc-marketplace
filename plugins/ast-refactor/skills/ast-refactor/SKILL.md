---
name: ast-refactor
description: Use when the user asks to rename, refactor, analyze code structure, find references, detect dead code, check complexity, move symbols, extract functions, inline variables, change function signatures, validate syntax, view dependency graphs, or add a new language. Triggers on keywords like "rename", "refactor", "find references", "symbol rename", "dead code", "unused imports", "complexity", "dependency graph", "import map", "type hierarchy", "extract function", "inline variable", "move symbol", "change signature", "validate", "add language", "code stats", "diff impact", "rename file", "rename case", "batch rename".
---

# AST Refactor Plugin

tree-sitter AST-based refactoring and analysis toolkit. Accurately processes only code symbols, excluding strings and comments.

**Script path**: `~/.claude/plugins/local/ast-refactor/scripts/`
**Supported languages**: TypeScript/JavaScript, Python, Java, Kotlin

## Core Rules

1. **Always run `--dry-run` first for modification scripts** → Show results to user → Execute after confirmation
2. **Always run `validate.sh` after modifications** → Check for syntax/import breakage
3. **Use `--format json`** → Parse results for follow-up decisions
4. **Submit feedback only on failure or critical defects** → See Feedback section below

## Choosing the Right Script

### When asked to "rename":

```
Single symbol rename?
├─ Entire project  → rename-symbol.sh --scope project
├─ Specific file   → rename-symbol.sh --scope file --file FILE
├─ Line range only → rename-symbol.sh --file FILE --start-line N --end-line M
└─ Selected refs   → selective-rename.sh --include-lines "N,M"

Multiple symbols at once?
└─ batch-rename.sh --map rename-map.json

Naming convention conversion? (camelCase→snake_case etc.)
└─ rename-case.sh --to snake

File rename + import update?
└─ rename-file.sh --file OLD --new NEW
```

### When asked to "refactor":

```
Extract code block into a new function?
└─ extract-function.sh --file FILE --start-line N --end-line M --name FUNC

Replace variable with its value and remove declaration?
└─ inline-variable.sh --symbol VAR --file FILE

Move symbol to another file?
└─ move-symbol.sh --symbol NAME --from FILE --to FILE

Add/remove/rename function parameters?
└─ change-signature.sh --symbol FUNC --add-param "name:type=default"
```

### When asked to "analyze":

```
Where is a symbol used?       → find-references.sh --symbol NAME --path DIR
List all symbols?             → symbol-list.sh --path DIR
Dead code?                    → dead-code.sh --path DIR
Unused imports?               → unused-imports.sh --path DIR
Function complexity?          → complexity-report.sh --path DIR --threshold 10
File dependency graph?        → dependency-graph.sh --path DIR --format mermaid
Import matrix?                → import-map.sh --path DIR --format table
Class inheritance hierarchy?  → type-hierarchy.sh --symbol CLASS --path DIR
Code statistics?              → code-stats.sh --path DIR
Change impact analysis?       → diff-impact.sh --commit HEAD~1..HEAD
```

## Execution Templates (copy-paste ready)

> `S=~/.claude/plugins/local/ast-refactor/scripts` is used as shorthand. Use the full path in practice.

### Find Symbol References

```bash
bash $S/find-references.sh --symbol SYMBOL_NAME --path ./src --format json
```

### Rename Symbol

```bash
# Step 1: dry-run
bash $S/rename-symbol.sh --symbol OLD_NAME --new NEW_NAME --path ./src --dry-run --format json

# Step 2: execute after user confirmation
bash $S/rename-symbol.sh --symbol OLD_NAME --new NEW_NAME --path ./src --format json

# Step 3: validate
bash $S/validate.sh --path ./src --format json
```

### Rename File

```bash
# Step 1: dry-run
bash $S/rename-file.sh --file src/old-name.ts --new src/new-name.ts --dry-run --format json

# Step 2: execute
bash $S/rename-file.sh --file src/old-name.ts --new src/new-name.ts --format json

# Step 3: validate
bash $S/validate.sh --path ./src --format json
```

### Rename Case (Naming Convention)

```bash
bash $S/rename-case.sh --symbol camelCaseName --to snake --path ./src --dry-run
```

Targets: `camel`, `snake`, `pascal`, `kebab`

### Selective Rename

```bash
# Step 1: list all references
bash $S/selective-rename.sh --symbol OLD --new NEW --path ./src

# Step 2: rename only specific lines
bash $S/selective-rename.sh --symbol OLD --new NEW --path ./src --include-lines "12,15,20" --dry-run
```

### Batch Rename

```bash
# Create rename-map.json first:
# {"renames": [{"old": "userId", "new": "accountId"}, {"old": "getData", "new": "fetchData"}]}

bash $S/batch-rename.sh --map rename-map.json --path ./src --dry-run
```

### Extract Function

```bash
bash $S/extract-function.sh --file src/utils.ts --start-line 10 --end-line 25 --name newFuncName --dry-run
```

### Inline Variable

```bash
bash $S/inline-variable.sh --symbol varName --file src/api.ts --dry-run
```

### Move Symbol

```bash
bash $S/move-symbol.sh --symbol SymbolName --from src/old.ts --to src/new.ts --path ./src --dry-run
```

### Change Function Signature

```bash
# Add parameter
bash $S/change-signature.sh --symbol funcName --path ./src --add-param "timeout:number=5000" --dry-run

# Remove parameter
bash $S/change-signature.sh --symbol funcName --path ./src --remove-param "legacyParam" --dry-run

# Rename parameter
bash $S/change-signature.sh --symbol funcName --path ./src --rename-param "oldParam:newParam" --dry-run

# Reorder parameters
bash $S/change-signature.sh --symbol funcName --path ./src --reorder-params "a,b,c" --dry-run
```

### Analysis (read-only — no dry-run needed)

```bash
# Symbol list
bash $S/symbol-list.sh --path ./src --format json

# Dead code detection
bash $S/dead-code.sh --path ./src --format json

# Unused import detection
bash $S/unused-imports.sh --path ./src --format json
# Auto-remove: add --fix

# Complexity analysis
bash $S/complexity-report.sh --path ./src --threshold 10 --format json

# Dependency graph
bash $S/dependency-graph.sh --path ./src --format mermaid

# Import matrix
bash $S/import-map.sh --path ./src --format table

# Class inheritance
bash $S/type-hierarchy.sh --symbol ClassName --path ./src --format json

# Code statistics
bash $S/code-stats.sh --path ./src --format json

# Change impact analysis
bash $S/diff-impact.sh --commit HEAD~1..HEAD --path ./src --format json
```

### Validate

```bash
bash $S/validate.sh --path ./src --format json
```

### Undo

```bash
bash $S/undo.sh --list
bash $S/undo.sh --last
```

### Git Integration

Add these options to any modification script:

```bash
--git                    # Auto-stage changed files
--git-commit "message"   # Auto-commit (includes --git)
```

## Standard Workflows

### Symbol Rename

```
find-references.sh (understand usage) → rename-symbol.sh --dry-run (preview) → user confirms → rename-symbol.sh (execute) → validate.sh (verify)
```

### Structural Change

```
symbol-list.sh (assess current state) → extract-function.sh / move-symbol.sh --dry-run → user confirms → execute → validate.sh (verify)
```

### Code Analysis

```
code-stats.sh (overview) → dead-code.sh + unused-imports.sh (detect issues) → complexity-report.sh (complexity) → summarize findings
```

## Config File (.refactorrc)

Auto-loaded from project root if present:

```json
{
  "exclude": ["node_modules", "dist", "build"],
  "backup": true,
  "git_integration": true,
  "validate_after_rename": true
}
```

Override: `--no-config`

## Adding a New Language

```bash
bash $S/add-language.sh --lang rust
```

Auto-detected: rust, go, ruby, c, cpp, csharp, swift, kotlin, php, scala

## Feedback

**Submit feedback ONLY when a script fails or produces critically wrong results.** Do NOT submit feedback on every successful use — only when something goes wrong.

### When to submit

| Situation | Action |
|-----------|--------|
| Script ran successfully | Do nothing |
| Script failed with an error | Submit with `--status fail` |
| Script produced incorrect/unexpected results | Submit with `--status fail` |
| Had to check `--help` and retry multiple times | Submit with `--status success --used-help --retries N` |
| Discovered a critical defect in the script | Submit with `--status fail --error "description"` |

### On failure

```bash
bash $S/submit-feedback.sh --script SCRIPT_NAME.sh --status fail \
  --error "Error message from the script"
```

### On critical defect

```bash
bash $S/submit-feedback.sh --script SCRIPT_NAME.sh --status fail \
  --error "Description of the defect" --message "What was attempted"
```

### When --help was needed to succeed

```bash
bash $S/submit-feedback.sh --script SCRIPT_NAME.sh --status success \
  --used-help --retries N --message "What was confusing"
```
