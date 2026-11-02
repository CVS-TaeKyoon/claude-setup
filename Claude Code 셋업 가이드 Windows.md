# Claude Code 셋업 가이드 (Windows native)

새 환경에서 현재 Claude Code 셋업을 재현하기 위한 단계별 가이드입니다.
**Windows native** 기준입니다. 순서대로 진행하세요 (0 → 5).
2번 단계부터는 선택 사항입니다 — 필요한 부분만 쓰세요.
다만 3번(statusline)은 2번에서 설치하는 `jq` 가 있어야 동작합니다.

> **요구 사항** — Windows 10 1809+ 또는 Windows Server 2019+, RAM 4GB 이상, x64 또는 ARM64.
> 계정은 Pro · Max · Team · Enterprise 또는 Console 중 하나가 필요합니다 (무료 플랜은 제외).

---

## 0. 의존성 설치

```powershell
# git (claude code / status-line)
winget install -e --id Git.Git

# github cli (claude code — PR/이슈 작업)
winget install -e --id GitHub.cli

# gitlab cli (claude code — MR/이슈 작업)
winget install -e --id GLab.GLab
```

### git 초기 설정

```powershell
# 에디터 변경 (vim 대신 vscode)
git config --global core.editor "code --wait"

# 초기 브랜치명 변경
git config --global init.defaultBranch main

# 사용자 정보
git config --global user.name "이름"
git config --global user.email "이메일"

# 줄바꿈 (Windows 개발자 표준)
git config --global core.autocrlf true
```

### gh 인증

```powershell
# GitHub 계정 로그인 (브라우저 인증)
gh auth login
```

> 프롬프트에서 `GitHub.com` → `HTTPS` → `Login with a web browser` 순으로 선택하면
> 브라우저가 열리고 일회용 코드 입력으로 인증이 완료됩니다.

### glab 인증

```powershell
# GitLab 계정 로그인 (토큰 인증)
glab auth login --hostname "호스트 주소"
```

> 프롬프트에서 GitLab 서버에서 발급받은 개인 토큰을 입력하고 인증을 완료합니다.

---

## 1. Claude Code 설치

```powershell
irm https://claude.ai/install.ps1 | iex
```

> 설치 스크립트가 PATH 설정까지 처리합니다. 설치 후 **새 터미널**을 열어 `claude` 를 실행하세요.

### 설치 확인

```powershell
# 버전 출력 — 예: 2.1.241 (Claude Code)
claude --version

# 설치·설정 진단 (읽기 전용, 세션을 시작하지 않음)
claude doctor
```

> `command not found` 가 나오면 새 터미널을 열지 않았거나 PATH가 아직 반영되지 않은 경우입니다.
> 네이티브 설치는 백그라운드에서 자동 업데이트됩니다.

---

## 2. Statusline 의존성 설치

```powershell
# jq (status-line)
winget install -e --id jqlang.jq
```

---

## 3. Statusline 표시

### 3-1. 스크립트 파일 복사

아래 내용을 `~/.claude/statusline.sh` 로 저장합니다.
(model | 디렉터리 | git 상태 / rate limit | 경과시간 / 컨텍스트 바 | 비용 | 토큰 사용량 표시)

> 의존성: `jq` (2번 단계), `git` (0번 단계), `timeout`·`stat` (Git Bash 내장)

```bash
#!/usr/bin/env bash
# Claude Code status line — Windows Git Bash, jq required (no Python)
# Line 1: model | directory | git branch (untracked/staged/modified/deleted counts)
# Line 2: rate limits | elapsed
# Line 3: context bar + % | API cost | token usage
#
# Dependencies: jq, stat (Git Bash built-in), git, timeout

input=$(cat)

# DEBUG: uncomment to dump raw JSON for inspection
# echo "$input" > /tmp/statusline-debug.json

# ── Validate jq availability ──────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo "statusline: jq not found. Install via: winget install jqlang.jq" >&2
  exit 1
fi

# ── Parse scalar fields via jq ────────────────────────────────────────────────
model=$(jq -r '.model.display_name // ""' <<< "$input")
model_id=$(jq -r '.model.id // "" | ascii_downcase' <<< "$input")
effort=$(jq -r '.effort.level // ""' <<< "$input")
cwd=$(jq -r '.cwd // .workspace.current_dir // ""' <<< "$input")
used_pct=$(jq -r '
  .context_window.used_percentage
  | if . != null then floor | tostring else "" end
' <<< "$input")
transcript_path=$(jq -r '.transcript_path // ""' <<< "$input" | sed 's|\\|/|g')

rl_5h=$(jq -r '
  .rate_limits.five_hour.used_percentage
  | if . != null then (100 - .) | floor | tostring else "" end
' <<< "$input")
rl_5h_reset=$(jq -r '.rate_limits.five_hour.resets_at // ""' <<< "$input")
rl_7d=$(jq -r '
  .rate_limits.seven_day.used_percentage
  | if . != null then (100 - .) | floor | tostring else "" end
' <<< "$input")
rl_7d_reset=$(jq -r '.rate_limits.seven_day.resets_at // ""' <<< "$input")

# ── Cost calculation ──────────────────────────────────────────────────────────
# Shared jq formatting snippet (3 decimal places fixed)
_JQ_FMT='
  def fmt_cost:
    if . == 0 then ""
    else
      (. * 1000 | round) as $r |
      ($r / 1000) |
      if . >= 1 then
        (($r / 1000 | floor | tostring) + "." + (($r % 1000) | tostring | ("0" * (3 - length)) + .))
      else
        "0." + (($r % 1000) | tostring | ("0" * (3 - length)) + .)
      end
    end;
'

total_cost=""
tok_in=0
tok_out=0
tok_cache_w=0
tok_cache_r=0

# Primary: cumulative session total from transcript
# Deduplication: only count assistant entries whose parentUuid is NOT another assistant uuid
# (each turn creates a 2-3 entry chain with identical token counts)
# 개선: transcript 2회 파싱(cost + token) → 1회 통합 파싱
#       INDEX() 해시맵으로 중복제거 O(n²) → O(n)
#       cost를 raw 숫자로 출력해 빈 줄 문제 원천 차단, fmt_cost는 bash에서 후처리
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  # jq: 5줄 고정 출력 (raw_cost / tok_in / tok_out / tok_cache_w / tok_cache_r)
  # cost는 tostring으로 출력 — fmt_cost를 jq 안에서 쓰면 0일 때 빈 문자열이 되어
  # jq `,` 연산자가 빈 줄을 생략, sed -n 'Np' 인덱스가 밀리는 버그 발생
  _transcript_out=$(jq -rs '
    [.[] | select(.type == "assistant")] as $aa |
    ($aa | map({(.uuid): 1}) | add // {}) as $uuid_set |
    [
      $aa[] |
      select(.parentUuid as $p | $uuid_set[$p] == null) |
      {
        mid: (.message.model // "" | ascii_downcase),
        it:  (.message.usage.input_tokens                // 0),
        ot:  (.message.usage.output_tokens               // 0),
        cw:  (.message.usage.cache_creation_input_tokens // 0),
        cr:  (.message.usage.cache_read_input_tokens     // 0)
      }
    ] as $rows |
    # Pricing (input / cache_write / cache_read / output — per MTok):
    # Fable 5 / Mythos 5: $10 / $12.50 / $1.00 / $50
    # Opus 5            : $5  / $6.25  / $0.50 / $25
    # Sonnet 5          : $3  / $3.75  / $0.30 / $15
    # Haiku 4.5         : $1  / $1.25  / $0.10 / $5
    ($rows | reduce .[] as $t (0;
      . + (
        if   ($t.mid | test("fable|mythos")) then ($t.it*10 + $t.cw*12.5 + $t.cr*1.00 + $t.ot*50) / 1000000
        elif ($t.mid | test("opus"))         then ($t.it*5  + $t.cw*6.25 + $t.cr*0.50 + $t.ot*25) / 1000000
        elif ($t.mid | test("sonnet"))       then ($t.it*3  + $t.cw*3.75 + $t.cr*0.30 + $t.ot*15) / 1000000
        elif ($t.mid | test("haiku"))        then ($t.it*1  + $t.cw*1.25 + $t.cr*0.10 + $t.ot*5)  / 1000000
        else                                      ($t.it*3  + $t.cw*3.75 + $t.cr*0.30 + $t.ot*15) / 1000000
        end
      )
    ) | tostring),
    ($rows | map(.it) | add // 0 | tostring),
    ($rows | map(.ot) | add // 0 | tostring),
    ($rows | map(.cw) | add // 0 | tostring),
    ($rows | map(.cr) | add // 0 | tostring)
  ' "$transcript_path" 2>/dev/null | tr -d '\r')

  # 5줄 고정 파싱
  _raw_cost=$(sed -n '1p'  <<< "$_transcript_out")
  tok_in=$(sed -n '2p'     <<< "$_transcript_out"); tok_in=${tok_in:-0}
  tok_out=$(sed -n '3p'    <<< "$_transcript_out"); tok_out=${tok_out:-0}
  tok_cache_w=$(sed -n '4p' <<< "$_transcript_out"); tok_cache_w=${tok_cache_w:-0}
  tok_cache_r=$(sed -n '5p' <<< "$_transcript_out"); tok_cache_r=${tok_cache_r:-0}

  # fmt_cost를 bash 측에서 적용
  if [ -n "$_raw_cost" ] && [ "$_raw_cost" != "0" ]; then
    total_cost=$(jq -rn --argjson v "$_raw_cost" "$_JQ_FMT"'$v | fmt_cost')
  fi
fi

# Fallback: context window snapshot estimate (used when transcript unavailable)
if [ -z "$total_cost" ]; then
  input_t=$(jq -r '.context_window.current_usage.input_tokens                // 0' <<< "$input")
  output_t=$(jq -r '.context_window.current_usage.output_tokens               // 0' <<< "$input")
  cache_w=$(jq -r '.context_window.current_usage.cache_creation_input_tokens  // 0' <<< "$input")
  cache_r=$(jq -r '.context_window.current_usage.cache_read_input_tokens      // 0' <<< "$input")

  total_cost=$(jq -rn \
    --argjson it "$input_t" --argjson ot "$output_t" \
    --argjson cw "$cache_w" --argjson cr "$cache_r" \
    --arg mid "$model_id" \
    "$_JQ_FMT"'
    ($it + $ot + $cw + $cr) as $total |
    if $total == 0 then ""
    else
      (if   ($mid | test("fable|mythos")) then ($it*10 + $cw*12.5 + $cr*1.00 + $ot*50) / 1000000
       elif ($mid | test("opus"))         then ($it*5  + $cw*6.25 + $cr*0.50 + $ot*25) / 1000000
       elif ($mid | test("sonnet"))       then ($it*3  + $cw*3.75 + $cr*0.30 + $ot*15) / 1000000
       elif ($mid | test("haiku"))        then ($it*1  + $cw*1.25 + $cr*0.10 + $ot*5)  / 1000000
       else                                    ($it*3  + $cw*3.75 + $cr*0.30 + $ot*15) / 1000000
       end) | fmt_cost
    end
  ')
fi

# ── Rate limit remaining time helper ─────────────────────────────────────────
now_epoch=$(date +%s)

# remaining time helper: returns "HH:MM:SS" or "Xd HH:MM:SS"
_remain() {
  local resets_at="$1"
  local include_days="$2"
  [ -z "$resets_at" ] || [ "$resets_at" = "null" ] && return
  local diff=$(( resets_at - now_epoch ))
  [ "$diff" -le 0 ] && echo "0h 0m 0s" && return
  local d=$(( diff / 86400 ))
  local h=$(( (diff % 86400) / 3600 ))
  local m=$(( (diff % 3600) / 60 ))
  local s=$(( diff % 60 ))
  if [ "$include_days" = "1" ]; then
    printf "%dd %02dh %02dm %02ds" "$d" "$h" "$m" "$s"
  else
    printf "%02dh %02dm %02ds" "$h" "$m" "$s"
  fi
}

rl_5h_remain=$(_remain "$rl_5h_reset" "0")
rl_7d_remain=$(_remain "$rl_7d_reset" "1")

# ── Elapsed time (세션 시작 시각 기준) ────────────────────────────────────────
# 우선순위:
#   1) transcript 파일명에서 타임스탬프 파싱 (YYYYMMDD_HHMMSS 또는 YYYY-MM-DDTHH-MM-SS 패턴)
#   2) stat -c "%W" (birth time, GNU stat 8.25+ / Git Bash)
#   3) stat -c "%Y" (mtime — 폴백, 부정확할 수 있음)
elapsed=""
if [ -n "$transcript_path" ]; then
  fname=$(basename "$transcript_path")
  start_epoch=""

  # 패턴 A: YYYYMMDD_HHMMSS  (예: 20250609_143022.jsonl)
  if [[ "$fname" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2}) ]]; then
    start_epoch=$(date -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s 2>/dev/null)
  # 패턴 B: YYYY-MM-DDTHH-MM-SS  (예: 2025-06-09T14-30-22.jsonl)
  elif [[ "$fname" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2})-([0-9]{2})-([0-9]{2}) ]]; then
    start_epoch=$(date -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s 2>/dev/null)
  fi

  # 방법 2: birth time (stat -c "%W")
  if [ -z "${start_epoch}" ] && [ -f "$transcript_path" ]; then
    btime=$(stat -c "%W" "$transcript_path" 2>/dev/null)
    [ "${btime:-0}" -gt 0 ] 2>/dev/null && start_epoch="$btime"
  fi

  # 방법 3: mtime 폴백
  if [ -z "${start_epoch}" ] && [ -f "$transcript_path" ]; then
    start_epoch=$(stat -c "%Y" "$transcript_path" 2>/dev/null)
  fi

  # 경과 시간 포맷
  if [ -n "${start_epoch}" ] && [ "$start_epoch" -gt 0 ] 2>/dev/null; then
    elapsed_s=$(( now_epoch - start_epoch ))
    if [ "$elapsed_s" -ge 0 ]; then
      h=$(( elapsed_s / 3600 ))
      m=$(( (elapsed_s % 3600) / 60 ))
      s=$(( elapsed_s % 60 ))
      if [ "$h" -gt 0 ]; then
        elapsed=$(printf "%dh%02dm" "$h" "$m")
      elif [ "$m" -gt 0 ]; then
        elapsed=$(printf "%dm%02ds" "$m" "$s")
      else
        elapsed=$(printf "%ds" "$s")
      fi
    fi
  fi
fi

# ── Git info (fast path) ──────────────────────────────────────────────────────
# 개선: git 명령어 5회 → 2회 (rev-parse + status --porcelain)
git_branch=""
git_staged_new=0
git_staged_mod=0
git_staged_del=0
git_modified=0
git_deleted=0
git_untracked=0

if [ -n "$cwd" ]; then
  git_root=$(timeout 1 git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$git_root" ]; then
    git_branch=$(timeout 1 git -C "$git_root" symbolic-ref --short HEAD 2>/dev/null)
    # status --porcelain 1회 호출로 staged/modified/deleted/untracked 동시 추출
    # -uall: untracked 디렉터리를 개별 파일로 펼친다 → find 루프 없이 grep -c 로 개수 확정.
    #        porcelain 은 공백/비ASCII 경로를 따옴표+8진 이스케이프로 감싸므로,
    #        경로를 파싱하는 방식은 그런 파일명에서 개수가 틀린다. 파싱 자체를 없앤다.
    git_status_out=$(timeout 2 git -C "$git_root" status --porcelain -uall 2>/dev/null)
    # grep -c 는 무매치 시 "0" 을 출력하고 exit 1 → `|| echo 0` 을 붙이면 "0" 이 두 줄이 되어
    # 이후 정수 비교가 깨진다. grep -c 는 항상 개수를 출력하므로 폴백이 필요 없다.
    git_staged_new=$(grep -c '^A'     <<< "$git_status_out" 2>/dev/null)
    git_staged_mod=$(grep -c '^[MRC]' <<< "$git_status_out" 2>/dev/null)
    git_staged_del=$(grep -c '^D'     <<< "$git_status_out" 2>/dev/null)
    git_modified=$(grep -c '^ M'      <<< "$git_status_out" 2>/dev/null)
    git_deleted=$(grep -c '^ D'       <<< "$git_status_out" 2>/dev/null)
    git_untracked=$(grep -c '^??'     <<< "$git_status_out" 2>/dev/null)
  fi
fi

# ── ANSI colors ───────────────────────────────────────────────────────────────
RESET='\033[0m'
CYAN='\033[36m'
YELLOW='\033[33m'
GREEN='\033[32m'
RED='\033[31m'
MAGENTA='\033[35m'
BLUE='\033[34m'
DIM='\033[2m'
BOLD_RED='\033[1;31m'

# ── Effort level color helper ────────────────────────────────────────────────
# 레벨이 높을수록 토큰 소비 경고 강도 증가: low→BLUE, medium→GREEN, high→YELLOW, xhigh→RED, max→BOLD RED
_effort_color() {
  case "$1" in
    low)    printf '%s' "$BLUE" ;;
    medium) printf '%s' "$GREEN" ;;
    high)   printf '%s' "$YELLOW" ;;
    xhigh)  printf '%s' "$RED" ;;
    max)    printf '%s' "$BOLD_RED" ;;
    *)      printf '%s' "$MAGENTA" ;;
  esac
}

# ── Shorten path ──────────────────────────────────────────────────────────────
home_norm=$(echo "$HOME" | sed 's|\\|/|g')
cwd_display=$(echo "$cwd" | sed 's|\\|/|g' | sed "s|^$home_norm|~|")

# ── Line 1: model | directory | git ──────────────────────────────────────────
line1=""
[ -n "$model" ]       && line1="${line1}${CYAN}🤖 ${model}${RESET}"
[ -n "$effort" ]      && line1="${line1}${DIM} - ${RESET}$(_effort_color "$effort")${effort}${RESET}"
[ -n "$cwd_display" ] && line1="${line1}${DIM} | ${RESET}${YELLOW}📁 ${cwd_display}${RESET}"

if [ -n "$git_branch" ]; then
  git_part="${GREEN}🌿 ${git_branch}${RESET}"
  [ "$git_untracked"  -gt 0 ] 2>/dev/null && git_part="${git_part}${GREEN} ?${git_untracked}${RESET}"
  [ "$git_staged_new" -gt 0 ] 2>/dev/null && git_part="${git_part}${GREEN} +${git_staged_new}${RESET}"
  [ "$git_staged_mod" -gt 0 ] 2>/dev/null && git_part="${git_part}${CYAN} ~${git_staged_mod}${RESET}"
  [ "$git_staged_del" -gt 0 ] 2>/dev/null && git_part="${git_part}${CYAN} -${git_staged_del}${RESET}"
  [ "$git_modified"   -gt 0 ] 2>/dev/null && git_part="${git_part}${YELLOW} ~${git_modified}${RESET}"
  [ "$git_deleted"    -gt 0 ] 2>/dev/null && git_part="${git_part}${RED} -${git_deleted}${RESET}"
  line1="${line1}${DIM} | ${RESET}${git_part}"
fi

# ── Token totals ──────────────────────────────────────────────────────────────
tok_total=$(( tok_in + tok_out + tok_cache_w + tok_cache_r ))

# Human-readable token formatter: 1234567 → 1.2M, 12345 → 12.3K, 999 → 999
_fmt_tok() {
  local n="${1:-0}"
  n=$(( n + 0 )) 2>/dev/null || n=0
  if [ "$n" -ge 1000000 ] 2>/dev/null; then
    printf "%d.%dM" $(( n / 1000000 )) $(( (n % 1000000) / 100000 ))
  elif [ "$n" -ge 1000 ] 2>/dev/null; then
    printf "%d.%dK" $(( n / 1000 )) $(( (n % 1000) / 100 ))
  else
    printf "%d" "$n"
  fi
}

tok_total_fmt=$(_fmt_tok "$tok_total")
tok_in_fmt=$(_fmt_tok "$tok_in")
tok_out_fmt=$(_fmt_tok "$tok_out")
tok_cache_r_fmt=$(_fmt_tok "$tok_cache_r")
tok_cache_w_fmt=$(_fmt_tok "$tok_cache_w")

# ── Rate limit color helper ───────────────────────────────────────────────────
# 잔여량 %에 따라 색상 반환: 0~20 → RED, 20~50 → YELLOW, 50~ → GREEN
_rl_color() {
  local pct="${1:-0}"
  pct=$(( pct + 0 )) 2>/dev/null || pct=0
  if [ "$pct" -le 20 ]; then
    printf '%s' "$RED"
  elif [ "$pct" -le 50 ]; then
    printf '%s' "$YELLOW"
  else
    printf '%s' "$GREEN"
  fi
}

# ── Line 2: rate limits | elapsed ────────────────────────────────────────────
line2=""

if [ -n "$rl_5h" ] || [ -n "$rl_7d" ]; then
  line2="${CYAN}🔋${RESET}"
  if [ -n "$rl_5h" ]; then
    _c5=$(_rl_color "$rl_5h")
    line2="${line2} ${YELLOW}5H${RESET} ${DIM}:${RESET} ${_c5}${rl_5h}%${RESET}"
    [ -n "$rl_5h_remain" ] && line2="${line2}${DIM} - ${RESET}${CYAN}${rl_5h_remain}${RESET}"
  else
    line2="${line2} ${YELLOW}5H${RESET} ${DIM}:${RESET} ${YELLOW}--%${RESET}"
  fi
  line2="${line2}${DIM} |${RESET}"
  if [ -n "$rl_7d" ]; then
    _c7=$(_rl_color "$rl_7d")
    line2="${line2} ${CYAN}🔋${RESET} ${YELLOW}7D${RESET} ${DIM}:${RESET} ${_c7}${rl_7d}%${RESET}"
    [ -n "$rl_7d_remain" ] && line2="${line2}${DIM} - ${RESET}${CYAN}${rl_7d_remain}${RESET}"
  else
    line2="${line2} ${CYAN}🔋${RESET} ${YELLOW}7D${RESET} ${DIM}:${RESET} ${YELLOW}--%${RESET}"
  fi
else
  line2="${CYAN}🔋${RESET} ${YELLOW}5H${RESET} ${DIM}:${RESET} ${YELLOW}--%${RESET}${DIM} | ${RESET}${CYAN}🔋${RESET} ${YELLOW}7D${RESET} ${DIM}:${RESET} ${YELLOW}--%${RESET}"
fi

if [ -n "$elapsed" ]; then
  line2="${line2}${DIM} | ${RESET}\033[97m⏱️ ${elapsed}${RESET}"
else
  line2="${line2}${DIM} | ${RESET}\033[97m⏱️ 0s${RESET}"
fi

# ── Line 3: context bar | cost | tokens ──────────────────────────────────────
line3=""

if [ -n "$used_pct" ]; then
  filled=$(( used_pct * 20 / 100 ))
  [ "$filled" -gt 20 ] && filled=20
  bar=""
  i=0
  while [ $i -lt $filled ]; do bar="${bar}█"; i=$((i+1)); done
  while [ $i -lt 20 ];      do bar="${bar}░"; i=$((i+1)); done
  line3="${line3}${MAGENTA}📊 [${bar}] ${used_pct}%${RESET}"
else
  line3="${line3}${MAGENTA}📊 [░░░░░░░░░░░░░░░░░░░░] --%${RESET}"
fi

if [ -n "$total_cost" ]; then
  line3="${line3}${DIM} | ${RESET}${BLUE}💰 ~\$${total_cost}${RESET}"
else
  line3="${line3}${DIM} | ${RESET}${BLUE}💰 ~\$0.000${RESET}"
fi

# Token usage: total (in↑ out↓ cr: cw:)
if [ "$tok_total" -gt 0 ] 2>/dev/null; then
  line3="${line3}${DIM} | ${RESET}${GREEN}🔢 ${tok_total_fmt} (↑${tok_in_fmt} ↓${tok_out_fmt} cr:${tok_cache_r_fmt} cw:${tok_cache_w_fmt})${RESET}"
else
  line3="${line3}${DIM} | ${RESET}${GREEN}🔢 0${RESET}"
fi

# ── Output ────────────────────────────────────────────────────────────────────
printf "%b\n" "$line1"
printf "%b\n" "$line2"
printf "%b\n" "$line3"
exit 0
```

### 3-2. Subagent Statusline 스크립트 파일 복사 (선택)

멀티 에이전트 실행 시 각 subagent 행을 커스텀 렌더링합니다.
아래 내용을 `~/.claude/subagent-statusline.sh` 로 저장합니다.
(타입 아이콘 | 작업명 | 모델 | 상태 배지 | 경과시간 | 토큰 수 | 작업 디렉터리 표시)

> 의존성: `jq`
>
> 모델 표시는 Claude Code **v2.1.205 이상**에서 동작합니다.
> 그 이전 버전이거나 아직 모델이 확정되지 않은 subagent 에서는 해당 항목만 생략되고
> 나머지 표시는 그대로 유지됩니다.

```bash
#!/usr/bin/env bash
# Claude Code subagent status line — Windows Git Bash, jq required
#
# agent 패널의 각 subagent 행 본문(content)을 커스텀 렌더한다.
# 입력(stdin): base hook 필드 + columns + tasks[] 배열
#   tasks[].{ id, name, type, status, description, label, startTime, model,
#             effort, contextWindowSize, tokenCount, tokenSamples, cwd }
#   model/contextWindowSize 는 v2.1.205+, effort 는 v2.1.214+ 에서 제공되고
#   아직 모델이 확정되지 않은 task 에서는 생략된다.
# 출력(stdout): 오버라이드할 행마다 {"id":..,"content":..} JSON 한 줄
#   - content 는 ANSI/OSC8 포함 그대로 렌더됨
#   - id 생략 시 기본 렌더 유지, 빈 content 는 행 숨김
#
# 행 레이아웃:
#   <type아이콘> <name|type>  <model>  <status배지>  ⏱<duration>  🔢<tokens>  [📁<folder>]

input=$(cat)

# DEBUG: 실제 패널에서 startTime 단위 / status 값 집합 확인용 (필요 시 주석 해제)
# echo "$input" > /tmp/subagent-statusline-debug.json

# jq 없으면 조용히 종료 → 기본 렌더 유지
command -v jq &>/dev/null || exit 0

# ── 터미널 너비 (부모 cwd 비교는 아래 메인 파싱 jq 안에서 처리) ──────────────
columns=$(jq -r '.columns // empty' <<< "$input")
[ -n "$columns" ] && [ "$columns" -gt 0 ] 2>/dev/null || columns=${COLUMNS:-80}

now_epoch=$(date +%s)

# ── ANSI colors (기존 statusline 팔레트 재사용, 실제 ESC 바이트로 정의) ──────
RESET=$'\033[0m'
CYAN=$'\033[36m'
YELLOW=$'\033[33m'
GREEN=$'\033[32m'
RED=$'\033[31m'
MAGENTA=$'\033[35m'
BLUE=$'\033[34m'
DIM=$'\033[2m'
WHITE=$'\033[97m'

# ── type → "아이콘|색상" 매핑 ──────────────────────────────────────────────
_type_style() {
  local t
  t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$t" in
    explore*)           printf '🔍|%s' "$CYAN" ;;
    *architect*)        printf '📐|%s' "$BLUE" ;;
    plan*)              printf '📐|%s' "$MAGENTA" ;;
    *review*)           printf '🔎|%s' "$YELLOW" ;;
    code-*|*explorer*)  printf '🔎|%s' "$BLUE" ;;
    *simplif*)          printf '✂️|%s' "$CYAN" ;;
    general*)           printf '⚙️|%s' "$GREEN" ;;
    statusline*)        printf '📊|%s' "$MAGENTA" ;;
    local_agent|local*) printf '🤖|%s' "$CYAN" ;;
    *)                  printf '🤖|%s' "$WHITE" ;;
  esac
}

# ── status → 배지 ──────────────────────────────────────────────────────────
_status_badge() {
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$s" in
    "")                                  printf '' ;;
    *run*|*progress*|*active*)           printf '%s● running%s'  "$YELLOW" "$RESET" ;;
    *complet*|*done*|*success*|*finish*) printf '%s✓ done%s'     "$GREEN"  "$RESET" ;;
    *err*|*fail*)                        printf '%s✗ error%s'    "$RED"    "$RESET" ;;
    *pend*|*wait*|*queue*)               printf '%s◌ pending%s'  "$DIM"    "$RESET" ;;
    *)                                   printf '%s%s%s'         "$DIM" "$1" "$RESET" ;;
  esac
}

# ── model ID → "표시라벨|색상" 매핑 ───────────────────────────────────────
# 실측값: sonnet 지정 → claude-sonnet-5, opus 지정 → claude-opus-5[1m]
#   - "[1m]" 같은 변형 접미사와 날짜 스냅샷(-20251001)은 떼고 계열+버전만 남긴다
#   - 알 수 없는 ID 는 claude- 접두만 떼고 그대로 노출 (임의 축약보다 낫다)
_model_style() {
  local m ver
  m="${1%%\[*}"          # 변형 접미사 제거
  m="${m#claude-}"
  ver="${m#*-}"
  [ "$ver" = "$m" ] && ver=""                                   # 버전 없는 ID
  ver="${ver%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"        # 날짜 스냅샷 제거
  ver="${ver//-/.}"
  case "$m" in
    opus*)   printf 'Opus%s|%s'   "${ver:+ $ver}" "$MAGENTA" ;;
    sonnet*) printf 'Sonnet%s|%s' "${ver:+ $ver}" "$CYAN" ;;
    haiku*)  printf 'Haiku%s|%s'  "${ver:+ $ver}" "$GREEN" ;;
    fable*)  printf 'Fable%s|%s'  "${ver:+ $ver}" "$BLUE" ;;
    *)       printf '%s|%s'       "$m"            "$DIM" ;;
  esac
}

# ── startTime → 경과시간 (epoch s/ms, ISO 모두 방어적 처리) ─────────────────
_duration() {
  local st="$1" start_s=""
  [ -z "$st" ] || [ "$st" = "null" ] && return
  if [[ "$st" =~ ^[0-9]+$ ]]; then
    if [ "${#st}" -ge 13 ]; then start_s=$(( st / 1000 ))   # epoch ms
    else                         start_s="$st"; fi          # epoch s
  elif [[ "$st" =~ ^[0-9]+\.[0-9]+$ ]]; then
    start_s=${st%%.*}                                       # epoch s.fraction
  else
    start_s=$(date -d "$st" +%s 2>/dev/null)                # ISO 등
  fi
  [ -z "$start_s" ] && return
  [ "$start_s" -gt 0 ] 2>/dev/null || return
  local diff=$(( now_epoch - start_s ))
  [ "$diff" -lt 0 ] && diff=0
  local h=$(( diff / 3600 )) m=$(( (diff % 3600) / 60 )) s=$(( diff % 60 ))
  if   [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm%02ds' "$m" "$s"
  else                      printf '%ds' "$s"; fi
}

# ── 토큰 K/M 포맷 (기존 _fmt_tok 이식) ─────────────────────────────────────
_fmt_tok() {
  local n="${1:-0}"
  n=$(( n + 0 )) 2>/dev/null || n=0
  if   [ "$n" -ge 1000000 ] 2>/dev/null; then printf "%d.%dM" $(( n / 1000000 )) $(( (n % 1000000) / 100000 ))
  elif [ "$n" -ge 1000 ]    2>/dev/null; then printf "%d.%dK" $(( n / 1000 ))    $(( (n % 1000) / 100 ))
  else                                          printf "%d" "$n"; fi
}

# ── tasks 순회 → 행마다 JSON 출력 ──────────────────────────────────────────
# 성능: jq 프로세스 호출을 task 수와 무관하게 고정한다 (Windows spawn 비용이 큼).
#   입력 파싱 @tsv 1회 + 출력 인코딩 1회. 루프 본문은 순수 bash(프로세스 spawn 없음).
#   → 한 새로고침 tick 안에 끝나 깜빡임(기본 렌더 폴백)을 방지.
#
# 입력 파싱: 각 task 를 [id, 작업명, type, status, startTime, tokenCount, model, folder] 로 추출.
#   - 작업명: name 은 보통 null → label/description 폴백 (실측 확인)
#   - folder: task.cwd 를 부모 cwd 와 비교, 다르면 basename, 같으면 "" (백슬래시 정규화 포함)

SEP=" ${DIM}|${RESET} "             # 항목 구분자 (기존 statusline " | " 스타일)
maxlabel=$(( columns / 2 ))
[ "$maxlabel" -lt 12 ] && maxlabel=12

rows=()
# 필드 구분자는 US(0x1f) — 탭은 IFS whitespace 라 빈 필드가 병합되어 컬럼이 밀린다.
while IFS=$'\x1f' read -r id name type status start tokens model folder; do
  folder=${folder%$'\r'}   # Windows jq 가 출력 줄 끝에 CRLF → 마지막 필드 CR 제거
  [ -z "$id" ] && continue

  IFS='|' read -r icon color <<< "$(_type_style "$type")"
  badge=$(_status_badge "$status")
  IFS='|' read -r mlabel mcolor <<< "$(_model_style "$model")"
  dur=$(_duration "$start")
  tok=$(_fmt_tok "$tokens")

  # 작업명이 너무 길면 columns 절반 기준으로 잘라냄
  label="$name"
  if [ "${#label}" -gt "$maxlabel" ]; then
    label="${label:0:$((maxlabel - 1))}…"
  fi

  # content 조립 (실제 ESC 바이트 포함 → 아래 jq 가 안전 인코딩)
  # 이모지는 터미널 폭(2셀) 계산 불일치로 다음 글자와 겹칠 수 있어 뒤에 공백을 둔다.
  # type 은 실측상 항상 "local_agent" 라 의미 구분이 없어 텍스트 생략, 아이콘만 표시.
  content="${color}${icon}${RESET}"
  [ -n "$label" ]                 && content="${content}  ${color}${label}${RESET}"
  [ -n "$mlabel" ]                && content="${content}${SEP}${mcolor}${mlabel}${RESET}"
  [ -n "$badge" ]                 && content="${content}${SEP}${badge}"
  [ -n "$dur" ]                   && content="${content}${SEP}${DIM}⏱${RESET}  ${dur}"
  [ "$tokens" -gt 0 ] 2>/dev/null && content="${content}${SEP}${GREEN}🔢  ${tok}${RESET}"
  [ -n "$folder" ]                && content="${content}${SEP}${YELLOW}📁  ${folder}${RESET}"

  # id + content 를 탭으로 묶어 축적 (content 에는 탭/개행 없음)
  rows+=("${id}"$'\t'"${content}")
done < <(jq -r '
  . as $root |
  (($root.cwd // $root.workspace.current_dir // "") | gsub("\\\\"; "/")) as $base |
  $root.tasks[]? |
  (((.cwd // "") | gsub("\\\\"; "/"))) as $tc |
  (if $tc != "" and $tc != $base then ($tc | split("/") | last) else "" end) as $folder |
  [ (.id // ""),
    ((.name // .label // .description // "") | gsub("[\n\r\t]"; " ")),
    (.type // ""),
    (.status // ""),
    (.startTime // "" | tostring),
    (.tokenCount // 0 | tostring),
    (.model // ""),
    $folder
  ] | join("")
' <<< "$input")

# 출력: 축적된 행을 jq 1회로 JSON object 줄들로 인코딩 (ESC →  안전)
[ "${#rows[@]}" -eq 0 ] && exit 0
printf '%s\n' "${rows[@]}" | jq -Rc 'select(length > 0) | split("\t") | {id: .[0], content: (.[1] // "")}' | tr -d '\r'

exit 0
```

### 3-3. settings.json 설정

`~/.claude/settings.json` 에 아래 두 키를 추가합니다.

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh",
    "refreshInterval": 30
  },
  "subagentStatusLine": {
    "type": "command",
    "command": "bash ~/.claude/subagent-statusline.sh"
  }
}
```

> 파일이 이미 있고 다른 설정이 들어 있다면, 바깥 `{ }` 는 그대로 두고
> **두 키만 최상위에 병합**하세요. 키 사이의 쉼표를 빠뜨리지 않도록 주의합니다.

---

## 4. 커스텀 테마 적용

내가 보낸 프롬프트의 **배경색·글자색**을 바꿉니다.
(짙은 cyan 배경 + 연노랑 글자)

> ⚠️ 배경색을 칠하는 `userMessageBackground` 토큰은 **풀스크린 렌더링 모드에서만** 보입니다.
> 최신 버전은 풀스크린이 **기본값**이지만, Classic 렌더러라면 색이 나타나지 않습니다 (4-3 참고).

### 4-1. 테마 파일 저장

아래 내용을 `~/.claude/themes/better-dark-theme.json` 으로 저장합니다.
Claude Code는 테마를 **이 폴더에서만** 읽습니다.

```json
{
  "name": "Better Dark Theme",
  "base": "dark",
  "overrides": {
    "userMessageBackground": "#164e63",
    "subtle": "#fef08a"
  }
}
```

폴더가 없으면 먼저 만듭니다.

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\themes"
```

- **파일 이름**(`.json` 제외)이 테마 슬러그가 됩니다 → `better-dark-theme`
- `name` 은 `/theme` 목록에 표시될 이름입니다 → `Better Dark Theme`
- `base` 는 나머지 색을 물려받을 기본 프리셋입니다 — `dark` · `light` · `dark-daltonized` ·
  `light-daltonized` · `dark-ansi` · `light-ansi` (생략 시 `dark`)
- 파일을 저장하면 **실행 중인 세션에도 자동 반영**됩니다 (재시작 불필요)
  단, `~/.claude/themes/` 폴더가 **없는 상태로 Claude Code를 시작**했다면
  첫 테마 파일을 만든 뒤 한 번은 재시작해야 합니다.

**overrides 토큰**

| 토큰 | 적용 대상 |
|---|---|
| `userMessageBackground` | 내가 보낸 프롬프트의 배경 (풀스크린 모드 전용) |
| `subtle` | 흐릿한 테두리·보조 텍스트 (상단 고정 프롬프트 글자 포함) |

> `subtle` 은 상단 프롬프트 글자뿐 아니라 힌트·비활성 항목 등 **다른 보조 텍스트에도 함께** 적용됩니다.
> 그 영역만 단독으로 칠하는 토큰은 없습니다.

### 4-2. 테마 선택

입력창에서:

```
/theme
```

목록에서 **Better Dark Theme** 를 선택합니다.
선택하면 `~/.claude/settings.json` 에 `"theme": "custom:better-dark-theme"` 로 저장됩니다.

### 4-3. 풀스크린 렌더링 확인

`userMessageBackground` 는 **풀스크린 렌더링 모드에서만** 적용됩니다.
다만 **최신 버전에서는 풀스크린이 기본값**이므로, 아래에 해당하면 이 단계에서 할 일이 없습니다.

- Claude Code를 **2026년 5월 6일 이후** 처음 사용한 경우
- 기능 플래그를 받지 않는 환경(Bedrock · Vertex · Foundry, 텔레메트리 비활성)이라면,
  그 머신의 **최초 실행이 v2.1.239 이상**인 경우

**확인 방법** — 인수 없이 실행하면 현재 렌더러를 알려줍니다.

```
/tui
```

> 입력창이 화면 하단에 **고정**되어 출력이 흘러도 움직이지 않으면 풀스크린이 켜진 상태입니다.

**Classic 렌더러로 시작하는 경우** — 아래 상황에서는 기본값이 Classic입니다.

| 상황 | 렌더러 |
|---|---|
| 위 조건보다 먼저 Claude Code를 쓰기 시작한 계정 | Classic (시작 시 전환 제안이 뜰 수 있음 — 최대 3회) |
| 이전에 풀스크린 시작이 실패한 이력이 있는 머신 | Classic |
| iTerm2 `tmux -CC` 통합 모드 / Windows 호스트로 SSH 접속 | Classic |
| 스크린리더 모드 | **항상** Classic |

이 경우 아래 명령으로 전환합니다.

```
/tui fullscreen
```

대화 내용을 유지한 채 재시작하며, `~/.claude/settings.json` 에 `"tui": "fullscreen"` 이 저장되어
다음 세션부터도 풀스크린으로 시작합니다. 되돌릴 때는 `/tui default` 입니다.

> 스크린리더 모드에서는 `/tui fullscreen` 이 전환 대신 안내 메시지를 출력합니다.
> 이 모드에서는 `userMessageBackground` 를 쓸 수 없습니다.

> 풀스크린 시작이 실패해 Claude Code가 자동으로 Classic으로 되돌린 뒤에도 강제하려면
> 환경변수 `CLAUDE_CODE_NO_FLICKER=1` 을 씁니다 (`tui` 설정보다 우선).
> 기본값으로 이미 켜지는 환경에서는 설정할 필요가 없습니다.

### 4-4. 색상 바꾸기 (선택)

`~/.claude/themes/better-dark-theme.json` 의 값만 바꿔 저장하면 바로 반영됩니다.
색상 형식은 `#rrggbb`, `#rgb`, `rgb(r,g,b)`, `ansi256(n)`, `ansi:<이름>` 을 모두 씁니다.

| 배경색 | 설명 | 가독성 |
|---|---|---|
| `#062c33` | 아주 짙은 cyan | ★★★ |
| `#164e63` | 짙은 cyan (4-1의 예시 값) | ★★★ |
| `#155e75` | 중간 cyan | ★★☆ |
| `ansi:cyan` | 표준 밝은 cyan | ★☆☆ |

> 배경은 짙을수록 흰 텍스트가 잘 보입니다.
> 어떤 토큰이 어느 글자를 지배하는지 헷갈리면, 그 토큰을 `#ff0000` 같은 색으로
> 잠깐 바꿔 적용해 보면 영향 범위를 바로 확인할 수 있습니다.

---

## 5. 공식 플러그인 설치

> `claude-plugins-official` 마켓플레이스는 Claude Code에 기본 내장되어 있어
> 별도 `marketplace add` 없이 바로 설치할 수 있습니다.

```powershell
# explanatory-output-style — 교육형(설명형) 출력 스타일
claude plugin install explanatory-output-style@claude-plugins-official
```

---

## 다음 단계

셋업이 끝났으면 **확장 가이드**로 넘어가세요.
`CLAUDE.md` · skill · 서브에이전트 · hook · MCP · plugin 을 내 작업에 맞게 붙이는 방법을 다룹니다.

> `Claude Code 확장 가이드 Windows.md`
