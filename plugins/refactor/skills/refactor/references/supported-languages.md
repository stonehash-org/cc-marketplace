# Supported Languages

| Language | Extensions | Query File | Status |
|----------|-----------|------------|--------|
| typescript | `*.ts`, `*.tsx`, `*.js`, `*.jsx`, `*.mjs`, `*.cjs` | `queries/typescript/symbols.scm` | ready |
| python | `*.py` | `queries/python/symbols.scm` | ready |
| java | `*.java` | `queries/java/symbols.scm` | ready |

## Adding a New Language

```bash
bash ~/.claude/plugins/local/refactor/scripts/add-language.sh --lang <name>
```

Known auto-detected languages: rust, go, ruby, c, cpp, csharp, swift, kotlin, php, scala

For unlisted languages, provide `--grammar-url`:

```bash
bash ~/.claude/plugins/local/refactor/scripts/add-language.sh \
  --lang custom --grammar-url https://github.com/user/tree-sitter-custom
```

After adding, edit `queries/<lang>/symbols.scm` to define AST patterns.
Use `tree-sitter parse <sample-file>` to discover node types.
| kotlin | `*.kotlin` | `queries/kotlin/symbols.scm` | template |
