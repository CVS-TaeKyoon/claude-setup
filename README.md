# Claude Code 셋업 (Windows)

Windows에서 Claude Code를 팀 공통 환경으로 설정하기 위한 자료입니다.

- `Claude Code 셋업 가이드 Windows.md` — 수동 셋업 단계별 가이드
- `prompts/windows-claude-code-customization.ko.md` — Claude Desktop만 있는 PC에서 Claude Code 설치부터 Statusline·테마·플러그인 설정까지 AI가 자동으로 진행하는 프롬프트 (Claude Desktop 새 채팅에 붙여 넣기)
- `.claude/` — `~/.claude`에 복사할 팀 설정 파일 (Statusline 스크립트, 테마)
- `.claude.zip` — `.claude/` 내용을 묶은 배포용 압축 파일

## 배포

프롬프트는 [Releases](http://192.168.54.50:3000/tkkim/claude-setup/releases)의 **최신 릴리스**에 첨부된 `.claude.zip`을 내려받습니다.
설정을 바꿨다면 `.claude/` 내용을 다시 압축해 새 태그(예: `v1.0.1`)로 릴리스를 만들고 `.claude.zip`을 첨부하세요.

```bash
tea releases create --login crevis-gitea --repo tkkim/claude-setup --tag v1.0.1 --title "claude 설정 설치 파일" --asset .claude.zip
```
