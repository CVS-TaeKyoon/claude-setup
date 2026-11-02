# Claude Code 셋업 (Windows)

> ### 👉 [새 사용자 설치 프롬프트 바로가기](prompts/windows-claude-code-customization.ko.md)
>
> Claude Desktop만 설치된 PC에서, 링크한 문서의 코드 블록 전체를 복사해 Claude Desktop 새 채팅(Code 화면)에 붙여 넣으세요.
> Claude Code 설치부터 Statusline·테마·플러그인 설정까지 AI가 자동으로 진행합니다. 직접 할 일은 Claude 로그인과 관리자 권한 승인뿐입니다.

Windows에서 Claude Code를 팀 공통 환경으로 설정하기 위한 자료입니다.

- `Claude Code 셋업 가이드 Windows.md` — 수동 셋업 단계별 가이드
- `prompts/windows-claude-code-customization.ko.md` — Claude Desktop만 있는 PC에서 Claude Code 설치부터 Statusline·테마·플러그인 설정까지 AI가 자동으로 진행하는 프롬프트 (Claude Desktop 새 채팅에 붙여 넣기)
- `.claude/` — `~/.claude`에 복사할 팀 설정 파일 (Statusline 스크립트, 테마)
- `.claude.zip` — `.claude/` 내용을 묶은 배포용 압축 파일

## 배포

프롬프트는 [Releases](https://github.com/CVS-TaeKyoon/claude-setup/releases)의 **최신 릴리스**에 첨부된 `claude.zip`을 로그인 없이 내려받습니다.

```
https://github.com/CVS-TaeKyoon/claude-setup/releases/latest/download/claude.zip
```

설정을 바꿨다면 `.claude/` 내용을 다시 압축해 `.claude.zip`을 갱신하고, 새 태그(예: `v1.0.1`)로 릴리스를 만들어 **`claude.zip`이라는 이름으로** 첨부하세요.
GitHub는 `.`으로 시작하는 첨부 파일 이름을 바꾸므로, 첨부할 때 이름 앞의 `.`을 뺍니다.

```bash
cp .claude.zip claude.zip && gh release create v1.0.1 claude.zip --title "claude 설정 설치 파일" --notes "변경 내용" && rm claude.zip
```
