# cc-mkp

개인용 Claude Code 플러그인 마켓플레이스입니다.
프로젝트 관리, 생산성 도구 등 자주 사용하는 플러그인을 모아 관리합니다.

---

## 설치 방법

Claude Code에서 아래 명령어를 입력하면 마켓플레이스가 등록됩니다.

```bash
/plugin marketplace add jaybee-sths/cc-mkp
```

등록 후 개별 플러그인을 설치할 수 있습니다.

---

## 플러그인 목록

| 플러그인 | 설명 | 버전 | 가이드 |
|----------|------|------|--------|
| **[clickup](plugins/clickup/)** | 자연어로 ClickUp 워크스페이스를 관리 (태스크, 스프린트, 문서, 타임트래킹 등) | 1.0.0 | [사용 가이드](plugins/clickup/README.md) |

---

## 새 플러그인 추가 방법

이 마켓플레이스에 새로운 플러그인을 추가하려면:

1. `plugins/플러그인명/` 디렉토리 생성
2. `.claude-plugin/plugin.json` 매니페스트 파일 작성
3. 필요에 따라 skills, commands, agents, hooks 추가
4. `.claude-plugin/marketplace.json`에 플러그인 등록

### 디렉토리 구조

```
cc-mkp/
├── .claude-plugin/
│   └── marketplace.json          # 마켓플레이스 매니페스트
├── plugins/
│   └── <플러그인명>/
│       ├── .claude-plugin/
│       │   └── plugin.json       # 플러그인 매니페스트
│       ├── .mcp.json             # MCP 서버 설정
│       ├── README.md             # 플러그인별 사용 가이드
│       └── skills/               # 스킬 정의
│           └── <스킬명>/
│               ├── SKILL.md
│               └── references/
└── README.md                     # 이 파일
```

---

## 문제 해결

### 플러그인이 보이지 않을 때

```bash
# 마켓플레이스 재등록
/plugin marketplace remove cc-mkp
/plugin marketplace add jaybee-sths/cc-mkp
```

### MCP 서버 연결 확인

```bash
claude mcp list
```

각 플러그인별 문제 해결은 해당 플러그인의 [사용 가이드](#플러그인-목록)를 참고하세요.
