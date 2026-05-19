#!/bin/bash
#
# analyze-bug.sh — 调 gpt-5.4-mini 分析单条 TAPD bug，输出结构化 JSON
#
# 用法: ./scripts/analyze-bug.sh <bug_json_file> [图片目录]
# 示例: ./scripts/analyze-bug.sh /tmp/bug-12345.json /tmp/images/12345
#
# 环境变量:
#   OPENAI_BASE_URL     — API 地址（默认: http://8.134.137.112:3001/v1）
#   OPENAI_API_KEY      — API Key
#   OPENAI_MODEL        — 模型（默认: gpt-5.4-mini）

set -euo pipefail

BUG_JSON="${1:?用法: $0 <bug_json_file> [图片目录]}"
IMG_DIR="${2:-}"
API_URL="${OPENAI_BASE_URL:-http://8.134.137.112:3001/v1}"
MODEL="${OPENAI_MODEL:-gpt-5.4-mini}"

# 读取 bug 数据
BUG_ID=$(jq -r '.id // .Id // empty' "$BUG_JSON" 2>/dev/null || echo "unknown")
TITLE=$(jq -r '.title // .Title // .name // .Name // empty' "$BUG_JSON" 2>/dev/null || echo "")
DESC=$(jq -r '.description // .Description // .content // .Content // empty' "$BUG_JSON" 2>/dev/null || echo "")
SEVERITY=$(jq -r '.severity // .Severity // .priority // .Priority // empty' "$BUG_JSON" 2>/dev/null || echo "unknown")
VERSION=$(jq -r '.version // .Version // .release // .Release // empty' "$BUG_JSON" 2>/dev/null || echo "")
MODULE=$(jq -r '.module // .Module // empty' "$BUG_JSON" 2>/dev/null || echo "")
STATUS=$(jq -r '.status // .Status // empty' "$BUG_JSOn" 2>/dev/null || echo "")

echo "🔍 分析 bug #$BUG_ID: $TITLE"

# 构建 prompt
PROMPT="你是一个 QA 分析助手。分析以下 TAPD bug 信息，输出简洁的结构化摘要。

## Bug 信息
- ID: $BUG_ID
- 标题: $TITLE
- 描述: $(echo "$DESC" | head -c 2000)
- 严重级别: $SEVERITY
- 影响版本: $VERSION
- 模块: $MODULE
- 状态: $STATUS

请输出 JSON 格式（仅 JSON，无额外文字）：
{
  \"id\": \"$BUG_ID\",
  \"title\": \"从标题提取的简短摘要\",
  \"severity\": \"严重级别\",
  \"version\": \"影响版本\",
  \"module\": \"模块\",
  \"steps\": \"从描述中提取的复现步骤，分点列出\",
  \"expected\": \"期望行为\",
  \"actual\": \"实际行为\",
  \"screenshots\": [\"截图文件名列表\"]
}"

# 如果有截图，用 vision 模式
HAS_VISION=false
IMAGES=()
if [ -n "$IMG_DIR" ] && [ -d "$IMG_DIR" ]; then
  for img in "$IMG_DIR"/*.png "$IMG_DIR"/*.jpg "$IMG_DIR"/*.jpeg 2>/dev/null; do
    [ -f "$img" ] && IMAGES+=("$img")
  done
  [ ${#IMAGES[@]} -gt 0 ] && HAS_VISION=true
fi

# 构建 API 请求体
if [ "$HAS_VISION" = true ]; then
  echo "  👁️  包含 ${#IMAGES[@]} 张截图进行视觉分析"

  # 构建带图片的 messages
  # 用 python3 生成请求体（方便处理 base64）
  python3 -c "
import json, base64, sys

prompt = sys.stdin.read()

messages = [{
    'role': 'user',
    'content': [{'type': 'text', 'text': prompt}]
}]

# 最多带 3 张截图（避免 token 超限）
for img_path in sys.argv[1:4]:
    with open(img_path, 'rb') as f:
        b64 = base64.b64encode(f.read()).decode()
    messages[0]['content'].append({
        'type': 'image_url',
        'image_url': {'url': f'data:image/png;base64,{b64}'}
    })

body = {
    'model': '$MODEL',
    'messages': messages,
    'max_tokens': 800,
    'response_format': {'type': 'json_object'}
}

print(json.dumps(body))
" "$PROMPT" "${IMAGES[@]}" > /tmp/tapd-request-"$BUG_ID".json

else
  echo "  📝 纯文本分析（无截图）"
  python3 -c "
import json, sys
body = {
    'model': '$MODEL',
    'messages': [{'role': 'user', 'content': sys.stdin.read()}],
    'max_tokens': 800,
    'response_format': {'type': 'json_object'}
}
print(json.dumps(body))
" <<< "$PROMPT" > /tmp/tapd-request-"$BUG_ID".json
fi

# 调用 API
echo "  📡 调用 AI 模型..."
RESPONSE=$(curl -s "${API_URL}/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  -d @/tmp/tapd-request-"$BUG_ID".json 2>&1)

# 解析响应
RESULT=$(echo "$RESPONSE" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    content = data.get('choices', [{}])[0].get('message', {}).get('content', '')
    print(content)
except:
    print('{\"error\": \"解析响应失败\"}')
" 2>/dev/null)

# 输出结果
echo ""
echo "$RESULT"

# 保存到文件
mkdir -p /tmp/tapd-analyzed
echo "$RESULT" > "/tmp/tapd-analyzed/$BUG_ID.json"
echo ""
echo "✅ 分析结果已保存到 /tmp/tapd-analyzed/$BUG_ID.json"
