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
#   <type아이콘> <name|type>  <model - effort>  <status배지>  ⏱<duration>  🔢<tokens>  [📁<folder>]

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
BOLD_RED=$'\033[1;31m'

# ── effort → 색상 (statusline.sh 의 _effort_color 와 동일 규칙) ──────────────
# task.effort 는 메인의 .effort.level 과 달리 문자열 그대로이며, 숫자 토큰 예산일 수도 있다.
#   숫자 등 알 수 없는 값은 MAGENTA 로 그대로 노출.
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
# 입력 파싱: 각 task 를 [id, 작업명, type, status, startTime, tokenCount, model, effort, folder] 로 추출.
#   - 작업명: name 은 보통 null → label/description 폴백 (실측 확인)
#   - folder: task.cwd 를 부모 cwd 와 비교, 다르면 basename, 같으면 "" (백슬래시 정규화 포함)

SEP=" ${DIM}|${RESET} "             # 항목 구분자 (기존 statusline " | " 스타일)
maxlabel=$(( columns / 2 ))
[ "$maxlabel" -lt 12 ] && maxlabel=12

rows=()
# 필드 구분자는 US(0x1f) — 탭은 IFS whitespace 라 빈 필드가 병합되어 컬럼이 밀린다.
while IFS=$'\x1f' read -r id name type status start tokens model effort folder; do
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
  [ -n "$effort" ]                && content="${content}${DIM} - ${RESET}$(_effort_color "$effort")${effort}${RESET}"
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
    (.effort // "" | tostring),
    $folder
  ] | join("")
' <<< "$input")

# 출력: 축적된 행을 jq 1회로 JSON object 줄들로 인코딩 (ESC →  안전)
[ "${#rows[@]}" -eq 0 ] && exit 0
printf '%s\n' "${rows[@]}" | jq -Rc 'select(length > 0) | split("\t") | {id: .[0], content: (.[1] // "")}' | tr -d '\r'

exit 0
