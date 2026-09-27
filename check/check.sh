#!/usr/bin/env bash
# rangeset 的固定验收程序。**别改这个文件。**
#
# 用法：
#   bash check/check.sh                  跑全部 10 个场景
#   bash check/check.sh -list            列出全部场景
#   bash check/check.sh --only kill      只跑一组（kill / hygiene / discriminate / scale），可用逗号分隔
#
# 输出：逐场景 `PASS <组>/<名>` 或 `FAIL <组>/<名>  期望=… 实际=…`；
#       结尾 `结果：通过 x/N`；全过 exit 0，否则 exit 1。失败不早退，一次把问题全暴露。
#
# 场景分组（10 个）：
#   kill          3 —— 杀伤率 ≥ 阈值 / 用例在未变异实现上全绿 / 超时变异体按被杀计且报告一致
#   hygiene       3 —— 用例不读源码与字节码 / 不 import `_` 前缀私有符号 / 不依赖定时器与随机
#   discriminate  2 —— 成对语义近邻各有区分性输入 / 区分性输入必须落在公开 API 上
#   scale         2 —— 用例数 ≥ 40 / 单次全量变异检查 ≤ 120 秒（按本机标定，跑题机慢按比例放宽）
#
# 前提：本题要求「用例数 ≥ 40」且「杀伤率 ≥ 0.95」。两条没同时满足时，提交的用例集还算不上
# 一个有效解，除两条基线场景（kill/unmutated_green、hygiene/no_source_read）与纯计数/纯计时的
# scale/test_count 外，其余场景一律判 FAIL，并在「期望」里写明未满足的前提 ——
# 先把主项做出来，再看其它维度。
#
# 只依赖 bash、node 与标准 Unix 工具。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

THRESHOLD=0.95
MIN_TESTS=40
MAX_SECONDS=120

if ! command -v node >/dev/null 2>&1; then
  printf '找不到 node\n' >&2
  exit 2
fi

GATE_EXPECT="用例集已达规模与杀伤率要求（用例数≥${MIN_TESTS}、杀伤率≥$(printf '%.3f' "$THRESHOLD")）"

SCENARIO_KEYS=(
  kill/score
  kill/unmutated_green
  kill/timeout_accounting
  hygiene/no_source_read
  hygiene/no_private_symbol
  hygiene/no_time_random
  discriminate/pairs
  discriminate/public_api
  scale/test_count
  scale/runtime
)
SCENARIO_WHY=(
  "变异检查杀伤率 ≥ $(printf '%.3f' "$THRESHOLD")"
  "用例在未变异的实现上全绿（不许靠让实现失败来「杀」变异体）"
  "超时变异体按被杀计，且报告的被杀数与位点数一致"
  "用例不读源码与字节码（readFile / createRequire / __filename / Buffer.from / import() 带查询串）"
  "用例不 import \`_\` 前缀私有符号，也不碰私有路径段"
  "用例不依赖定时器、Math.random、Date.now"
  "4 对语义近邻各自都有能区分的用例"
  "区分性输入只落在公开 API（union/intersect/difference/complement/contains/measure/toList）上"
  "用例数 ≥ ${MIN_TESTS}"
  "单次全量变异检查 ≤ ${MAX_SECONDS} 秒（按本机标定，跑题机慢按比例放宽）"
)

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

pass_scenario() { printf 'PASS %s/%s\n' "$1" "$2"; return 0; }

fail_scenario() { printf 'FAIL %s/%s  期望=%s 实际=%s\n' "$1" "$2" "$3" "$4"; return 1; }

ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !((a+0) >= (b+0))}'; }

le() { awk -v a="$1" -v b="$2" 'BEGIN{exit !((a+0) <= (b+0))}'; }

# --- 一次全量变异检查（结果缓存，供多个场景复用） ---
MUTATE_RAN=0
MUTATE_SUMMARY=""

run_mutate() {
  if [ "$MUTATE_RAN" = "0" ]; then
    MUTATE_SUMMARY="$(bash check/mutate.sh 2>/dev/null | grep '^SUMMARY ' | tail -n 1)"
    MUTATE_RAN=1
  fi
}

mutate_field() {
  printf '%s\n' "$MUTATE_SUMMARY" | sed -n "s/.* $1=\([^ ]*\).*/\1/p"
}

# --- 一次 probe（hygiene / discriminate / scale 的进程内检查） ---
PROBE_RAN=0
PROBE_OUT=""

run_probe() {
  if [ "$PROBE_RAN" = "0" ]; then
    PROBE_OUT="$(node check/probe.mjs 2>&1)"
    PROBE_RAN=1
  fi
}

probe_field() {
  printf '%s\n' "$PROBE_OUT" | awk -v key="$1" '$1 == "RESULT" && $2 == key { $1 = ""; $2 = ""; sub(/^[ \t]+/, ""); print; exit }'
}

probe_status() {
  printf '%s\n' "$(probe_field "$1")" | awk '{print $1}'
}

probe_detail() {
  printf '%s\n' "$(probe_field "$1")" | sed 's/^[A-Za-z]* *//'
}

# --- 未变异实现上的用例套件 ---
GREEN_RAN=0
GREEN_STATUS=0
GREEN_NOTE=""

run_green() {
  if [ "$GREEN_RAN" = "0" ]; then
    local out
    out="$(node --test 2>&1)"
    GREEN_STATUS=$?
    GREEN_NOTE="$(printf '%s\n' "$out" | grep -E '^# (tests|pass|fail) ' | tr '\n' ' ')"
    GREEN_RAN=1
  fi
}

# --- 前提（gate） ---
gate_ok() {
  run_mutate
  local score count
  score="$(mutate_field score)"
  count="$(probe_field scale/test_count | sed -n 's/.*用例数 \([0-9]*\).*/\1/p')"
  [ -n "$score" ] || return 1
  ge "$score" "$THRESHOLD" || return 1
  if [ -n "$count" ]; then
    [ "$count" -ge "$MIN_TESTS" ] || return 1
  else
    return 1
  fi
  return 0
}

gate_reason() {
  run_mutate
  run_probe
  local score count
  score="$(mutate_field score)"
  count="$(probe_field scale/test_count | sed -n 's/.*用例数 \([0-9]*\).*/\1/p')"
  printf '用例数=%s（要求≥%d）、杀伤率=%s（要求≥%s）' \
    "${count:-?}" "$MIN_TESTS" "${score:-?}" "$(printf '%.3f' "$THRESHOLD")"
}

# ---------------------------------------------------------------------------
# 场景
# ---------------------------------------------------------------------------

sc_kill_score() {
  run_mutate
  local score sites killed
  score="$(mutate_field score)"
  sites="$(mutate_field sites)"
  killed="$(mutate_field killed)"
  if [ -n "$score" ] && ge "$score" "$THRESHOLD"; then
    pass_scenario kill score
  else
    fail_scenario kill score "杀伤率 ≥ $(printf '%.3f' "$THRESHOLD")" \
      "杀伤率 ${score:-无}（被杀 ${killed:-?} / 位点 ${sites:-?}）"
  fi
}

sc_kill_unmutated_green() {
  run_green
  if [ "$GREEN_STATUS" = "0" ]; then
    pass_scenario kill unmutated_green
  else
    fail_scenario kill unmutated_green "未变异实现上用例全绿（退出码 0）" \
      "退出码 $GREEN_STATUS；${GREEN_NOTE:-无摘要}"
  fi
}

sc_kill_timeout_accounting() {
  run_probe
  if ! gate_ok; then
    fail_scenario kill timeout_accounting "$GATE_EXPECT" "$(gate_reason)"
    return
  fi
  local out summary sites killed survived score
  out="$(bash check/mutate.sh --timeout 0.000001 2>&1)"
  summary="$(printf '%s\n' "$out" | grep '^SUMMARY ' | tail -n 1)"
  sites="$(printf '%s\n' "$summary" | sed -n 's/.* sites=\([^ ]*\).*/\1/p')"
  killed="$(printf '%s\n' "$summary" | sed -n 's/.* killed=\([^ ]*\).*/\1/p')"
  survived="$(printf '%s\n' "$summary" | sed -n 's/.* survived=\([^ ]*\).*/\1/p')"
  score="$(printf '%s\n' "$summary" | sed -n 's/.* score=\([^ ]*\).*/\1/p')"
  if [ "$survived" = "0" ] && [ -n "$score" ] && ge "$score" 1.0 && [ "$killed" = "$sites" ] && [ -n "$sites" ]; then
    pass_scenario kill timeout_accounting
  else
    fail_scenario kill timeout_accounting "极短超时下存活 0、杀伤率 1.000、被杀数=位点数" \
      "存活 ${survived:-?}、杀伤率 ${score:-?}、被杀 ${killed:-?} / 位点 ${sites:-?}"
  fi
}

sc_hygiene_no_source_read() {
  run_probe
  local detail
  detail="$(probe_field hygiene/no_source_read)"
  if [ "${detail%% *}" = "OK" ]; then
    pass_scenario hygiene no_source_read
  else
    fail_scenario hygiene no_source_read "用例不读源码与字节码" "$(probe_detail hygiene/no_source_read)"
  fi
}

sc_hygiene_no_private_symbol() {
  run_probe
  if ! gate_ok; then
    fail_scenario hygiene no_private_symbol "$GATE_EXPECT" "$(gate_reason)"
    return
  fi
  if [ "$(probe_status hygiene/no_private_symbol)" = "OK" ]; then
    pass_scenario hygiene no_private_symbol
  else
    fail_scenario hygiene no_private_symbol "只 import 公开符号，不碰 \`_\` 前缀名字与路径段" \
      "$(probe_detail hygiene/no_private_symbol)"
  fi
}

sc_hygiene_no_time_random() {
  run_probe
  if ! gate_ok; then
    fail_scenario hygiene no_time_random "$GATE_EXPECT" "$(gate_reason)"
    return
  fi
  if [ "$(probe_status hygiene/no_time_random)" = "OK" ]; then
    pass_scenario hygiene no_time_random
  else
    fail_scenario hygiene no_time_random "用例不依赖定时器与随机" \
      "$(probe_detail hygiene/no_time_random)"
  fi
}

sc_discriminate_pairs() {
  run_probe
  if ! gate_ok; then
    fail_scenario discriminate pairs "$GATE_EXPECT" "$(gate_reason)"
    return
  fi
  if [ "$(probe_status discriminate/pairs)" = "OK" ]; then
    pass_scenario discriminate pairs
  else
    fail_scenario discriminate pairs "4 对语义近邻各自的两种近似实现都被用例杀掉" \
      "$(probe_detail discriminate/pairs)"
  fi
}

sc_discriminate_public_api() {
  run_probe
  if ! gate_ok; then
    fail_scenario discriminate public_api "$GATE_EXPECT" "$(gate_reason)"
    return
  fi
  if [ "$(probe_status discriminate/public_api)" = "OK" ]; then
    pass_scenario discriminate public_api
  else
    fail_scenario discriminate public_api "每对语义近邻都有只走公开导出、返回不同值的区分性输入" \
      "$(probe_detail discriminate/public_api)"
  fi
}

sc_scale_test_count() {
  run_probe
  local detail count
  detail="$(probe_detail scale/test_count)"
  count="$(printf '%s\n' "$detail" | sed -n 's/.*用例数 \([0-9]*\).*/\1/p')"
  if [ "$(probe_status scale/test_count)" = "OK" ] && [ -n "$count" ] && [ "$count" -ge "$MIN_TESTS" ]; then
    pass_scenario scale test_count
  else
    fail_scenario scale test_count "用例数 ≥ $MIN_TESTS" "${detail:-?}"
  fi
}

sc_scale_runtime() {
  run_probe
  if ! gate_ok; then
    fail_scenario scale runtime "$GATE_EXPECT" "$(gate_reason)"
    return
  fi
  run_mutate
  local elapsed
  elapsed="$(mutate_field elapsed)"
  if [ -n "$elapsed" ] && le "$elapsed" "$MAX_SECONDS"; then
    pass_scenario scale runtime
  else
    fail_scenario scale runtime "全量变异检查 ≤ ${MAX_SECONDS} 秒（按本机标定，跑题机慢按比例放宽）" \
      "用时 ${elapsed:-?} 秒"
  fi
}

run_scenario() {
  case "$1" in
    kill/score)                     sc_kill_score ;;
    kill/unmutated_green)           sc_kill_unmutated_green ;;
    kill/timeout_accounting)        sc_kill_timeout_accounting ;;
    hygiene/no_source_read)         sc_hygiene_no_source_read ;;
    hygiene/no_private_symbol)      sc_hygiene_no_private_symbol ;;
    hygiene/no_time_random)         sc_hygiene_no_time_random ;;
    discriminate/pairs)             sc_discriminate_pairs ;;
    discriminate/public_api)        sc_discriminate_public_api ;;
    scale/test_count)               sc_scale_test_count ;;
    scale/runtime)                  sc_scale_runtime ;;
    *)                              return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

LIST_ONLY=0
ONLY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -list|--list) LIST_ONLY=1 ;;
    --only|--group)
      shift
      if [ "$#" -eq 0 ]; then
        printf -- '--only 需要一个组名（kill / hygiene / discriminate / scale）\n' >&2
        exit 2
      fi
      ONLY="$1"
      ;;
    -h|--help)
      printf '用法: bash check/check.sh [-list] [--only <组名>]\n'
      exit 0
      ;;
    *)
      printf '未知参数: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

if [ "$LIST_ONLY" = "1" ]; then
  index=0
  for key in "${SCENARIO_KEYS[@]}"; do
    printf '[%-12s] %-28s %s\n' "${key%%/*}" "$key" "${SCENARIO_WHY[$index]}"
    index=$((index + 1))
  done
  exit 0
fi

selected_count=0
passed=0
failed=0
index=0

# 先把两个「事实」各算一次（一次全量变异检查 + 一次 probe），后续场景复用。
run_mutate
run_probe

for key in "${SCENARIO_KEYS[@]}"; do
  group="${key%%/*}"
  why="${SCENARIO_WHY[$index]}"
  index=$((index + 1))
  if [ -n "$ONLY" ]; then
    case ",$ONLY," in
      *",$group,"*) ;;
      *) continue ;;
    esac
  fi
  selected_count=$((selected_count + 1))
  if run_scenario "$key"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi
done

if [ "$selected_count" = "0" ]; then
  printf '没有匹配的场景\n' >&2
  exit 2
fi

printf '结果：通过 %d/%d\n' "$passed" "$selected_count"
if [ "$failed" -eq 0 ]; then
  exit 0
fi
exit 1
