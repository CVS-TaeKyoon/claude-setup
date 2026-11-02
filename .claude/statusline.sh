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

# Shared jq pricing function (최신 모델만 — per MTok: [input, cache_read, output])
# Fable 5.1 / Mythos 5.1: $10   / $0.25 / $50
# Opus 5.5              : $4    / $0.20 / $20
# Sonnet 5.5            : $2    / $0.10 / $10
# Haiku 5.5 (≤100k)     : $0.10 / $0.01 / $0.50
# Haiku 5.5 (>100k)     : $0.50 / $0.05 / $2.50   ← 요청 1건의 프롬프트(it+cw+cr) 길이 기준
# Cache write: 5m = input × 1.25, 1h = input × 2
# 미지정 모델은 Sonnet 5.5 단가로 계산
_JQ_COST='
  def cost($mid; $it; $cw5; $cw1; $cr; $ot):
    ($it + $cw5 + $cw1 + $cr) as $prompt |
    (if   ($mid | test("fable|mythos")) then [10, 0.25, 50]
     elif ($mid | test("opus"))         then [4,  0.20, 20]
     elif ($mid | test("haiku")) then
       (if $prompt > 100000 then [0.50, 0.05, 2.50] else [0.10, 0.01, 0.50] end)
     else                                    [2,  0.10, 10]
     end) as [$pi, $pr, $po] |
    ($it*$pi + $cw5*$pi*1.25 + $cw1*$pi*2 + $cr*$pr + $ot*$po) / 1000000;
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
  _transcript_out=$(jq -rs "$_JQ_COST"'
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
        cw1: (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0),
        cr:  (.message.usage.cache_read_input_tokens     // 0)
      }
    ] as $rows |
    ($rows | reduce .[] as $t (0;
      . + cost($t.mid; $t.it; $t.cw - $t.cw1; $t.cw1; $t.cr; $t.ot)
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
  cache_w1=$(jq -r '.context_window.current_usage.cache_creation.ephemeral_1h_input_tokens // 0' <<< "$input")

  total_cost=$(jq -rn \
    --argjson it "$input_t" --argjson ot "$output_t" \
    --argjson cw "$cache_w" --argjson cw1 "$cache_w1" --argjson cr "$cache_r" \
    --arg mid "$model_id" \
    "$_JQ_FMT$_JQ_COST"'
    ($it + $ot + $cw + $cr) as $total |
    if $total == 0 then ""
    else cost($mid; $it; $cw - $cw1; $cw1; $cr; $ot) | fmt_cost
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