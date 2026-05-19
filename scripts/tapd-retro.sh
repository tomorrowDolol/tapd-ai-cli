#!/bin/bash
#
# tapd-retro.sh — TAPD 批量回顾：拉取本周 bug → 下载截图 → AI 分析 → Markdown 报告
#
# 用法: ./scripts/tapd-retro.sh [--workspace <id>] [--days 7] [--output <dir>]
#
# 环境变量:
#   TAPD_ACCESS_TOKEN    — TAPD API Token（或已用 tapd auth login）
#   OPENAI_BASE_URL      — API 地址
#   OPENAI_API_KEY       — API Key
#   OPENAI_MODEL         — 模型（默认: gpt-5.4-mini）

set -euo pipefail

# 解析参数
WORKSPACE_ID=""
DAYS=7
OUTPUT_DIR=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE_ID="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# 计算日期范围
END_DATE=$(date +%Y-%m-%d)
START_DATE=$(date -v-${DAYS}d +%Y-%m-%d 2>/dev/null || date -d "-${DAYS} days" +%Y-%m-%d 2>/dev/null || echo "unknown")

echo "════════════════════════════════════════"
echo "  TAPD 批量回顾"
echo "  $START_DATE ~ $END_DATE (${DAYS}天)"
echo "════════════════════════════════════════"
echo ""

# Step 1: 拉取 bug 列表
echo "📋 Step 1: 拉取 bug 列表..."
WORKSPACE_FLAG=""
[ -n "$WORKSPACE_ID" ] && WORKSPACE_FLAG="--workspace-id $WORKSPACE_ID"

# 先确保 workspace 已切换
if [ -n "$WORKSPACE_ID" ]; then
  tapd workspace switch "$WORKSPACE_ID" 2>/dev/null || true
fi

# 拉取已解决的 bug
BUGS=$(tapd bug list --status=resolved 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, list):
        print(json.dumps(data))
    elif isinstance(data, dict):
        # 可能是 {data: [...]} 格式
        items = data.get('data', data.get('list', []))
        print(json.dumps(items))
    else:
        print('[]')
except:
    print('[]')
")

BUG_COUNT=$(echo "$BUGS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

if [ "$BUG_COUNT" -eq 0 ]; then
  echo "  ⚠️  没有找到已解决的 bug"
  echo ""
  echo "📊 报告: 无数据"
  echo "  时间范围: $START_DATE ~ $END_DATE"
  exit 0
fi

echo "  找到 $BUG_COUNT 个 bug"
echo ""

# Step 2: 逐个分析
echo "🔬 Step 2: 逐个分析 bug..."
TEMP_DIR="/tmp/tapd-retro-$$"
mkdir -p "$TEMP_DIR"

SUCCESS=0
FAILED=0
RESULTS=()

echo "$BUGS" | python3 -c "
import json, sys, subprocess, os, tempfile

bugs = json.load(sys.stdin)
for i, bug in enumerate(bugs):
    bug_id = bug.get('id', bug.get('Id', f'bug-{i}'))
    print(f'  [{i+1}/{len(bugs)}] bug #{bug_id}...')

    # 保存 bug JSON
    bug_file = os.path.join('$TEMP_DIR', f'bug-{bug_id}.json')
    with open(bug_file, 'w') as f:
        json.dump(bug, f)

    # 下载截图
    img_dir = os.path.join('$TEMP_DIR', f'images-{bug_id}')
    os.makedirs(img_dir, exist_ok=True)
    subprocess.run(
        ['bash', '$SCRIPT_DIR/download-images.sh', str(bug_id), img_dir],
        capture_output=True, text=True, timeout=120
    )

    # AI 分析
    result = subprocess.run(
        ['bash', '$SCRIPT_DIR/analyze-bug.sh', bug_file, img_dir],
        capture_output=True, text=True, timeout=120
    )
    if result.returncode == 0:
        print(f'    ✅ 分析完成')
    else:
        print(f'    ⚠️  分析失败: {result.stderr[:100]}')
" 2>&1

echo ""
echo "✅ Step 2 完成"
echo ""

# Step 3: 生成 Markdown 报告
echo "📝 Step 3: 生成报告..."

REPORT_DIR="${OUTPUT_DIR:-$(pwd)/docs/bug-reports}"
mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/$END_DATE.md"

# 收集所有分析结果
{
  echo "# Bug 回顾报告 · $START_DATE ~ $END_DATE"
  echo ""
  echo "**总计:** $BUG_COUNT 个 bug | **分析时间:** $(date '+%Y-%m-%d %H:%M')"
  echo ""
  
  # 按严重级别分组
  echo "## 按严重级别"
  echo ""
  
  for SEV in "fatal" "serious" "normal" "prompt" "advice"; do
    SEV_BUGS=$(find /tmp/tapd-analyzed -name "*.json" -newer /tmp/tapd-analyzed 2>/dev/null || echo "")
    HAS=false
    for f in /tmp/tapd-analyzed/*.json; do
      [ -f "$f" ] || continue
      SEV_CUR=$(jq -r '.severity // "unknown"' "$f" 2>/dev/null)
      [ "$SEV_CUR" = "$SEV" ] && HAS=true && break
    done
    [ "$HAS" = false ] && continue
    
    echo "### ${SEV^}"
    echo ""
    
    for f in /tmp/tapd-analyzed/*.json; do
      [ -f "$f" ] || continue
      SEV_CUR=$(jq -r '.severity // "unknown"' "$f" 2>/dev/null)
      [ "$SEV_CUR" != "$SEV" ] && continue
      
      TITLE=$(jq -r '.title // "?"' "$f" 2>/dev/null)
      BUG_ID=$(jq -r '.id // "?"' "$f" 2>/dev/null)
      VERSION=$(jq -r '.version // "?"' "$f" 2>/dev/null)
      MODULE=$(jq -r '.module // "?"' "$f" 2>/dev/null)
      STEPS=$(jq -r '.steps // "?"' "$f" 2>/dev/null)
      EXPECTED=$(jq -r '.expected // "?"' "$f" 2>/dev/null)
      ACTUAL=$(jq -r '.actual // "?"' "$f" 2>/dev/null)
      SCREENSHOTS=$(jq -r '.screenshots[]? // empty' "$f" 2>/dev/null)
      
      echo "### $TITLE"
      echo "- **Bug ID:** $BUG_ID | **版本:** $VERSION | **模块:** $MODULE"
      echo ""
      echo "**复现步骤:**"
      echo "$STEPS"
      echo ""
      echo "| 期望 | 实际 |"
      echo "|------|------|"
      echo "| $EXPECTED | $ACTUAL |"
      echo ""
      if [ -n "$SCREENSHOTS" ]; then
        echo "![]($SCREENSHOTS)"
        echo ""
      fi
      echo "---"
      echo ""
    done
  done
} > "$REPORT_FILE"

echo "  📄 报告已保存: $REPORT_FILE"
echo ""
echo "════════════════════════════════════════"
echo "  ✅ TAPD 批量回顾完成"
echo "  📄 $REPORT_FILE"
echo "════════════════════════════════════════"
