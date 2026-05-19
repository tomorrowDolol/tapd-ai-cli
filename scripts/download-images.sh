#!/bin/bash
#
# download-images.sh — 从 TAPD 下载 bug 截图，超过 1MB 自动压缩
#
# 用法: ./scripts/download-images.sh <bug_id> [输出目录]
# 示例: ./scripts/download-images.sh 12345 /tmp/tapd-images
#
# 依赖: tapd CLI（已登录）, sips（macOS 自带）

set -euo pipefail

BUG_ID="${1:?用法: $0 <bug_id> [输出目录]}"
OUT_DIR="${2:-/tmp/tapd-images/$BUG_ID}"
mkdir -p "$OUT_DIR"

echo "📥 下载 bug #$BUG_ID 的截图..."

# 用 tapd image list 获取截图列表（JSON 格式）
IMAGES=$(tapd image list "$BUG_ID" 2>/dev/null || tapd attachment list "$BUG_ID" 2>/dev/null || echo "")

if [ -z "$IMAGES" ] || [ "$IMAGES" = "[]" ]; then
  echo "  ⚠️  无截图"
  echo "images=()" > "$OUT_DIR/.meta"
  exit 0
fi

echo "$IMAGES" | python3 -c "
import json, sys, subprocess, os

try:
    items = json.load(sys.stdin)
except:
    # 可能是其他格式，尝试解析
    print('WARN: 无法解析图片列表')
    sys.exit(1)

if not items:
    print('images=()')
    sys.exit(0)

out_dir = os.environ.get('OUT_DIR', '/tmp/tapd-images')
bug_id = os.environ.get('BUG_ID', '0')
downloaded = []
compressed = []

for item in items:
    # tapd image list 可能返回不同字段
    img_id = item.get('id', item.get('attachment_id', ''))
    img_name = item.get('name', item.get('title', f'image-{img_id}.png'))
    img_url = item.get('download_url', item.get('url', ''))

    if not img_url:
        # 尝试用 tapd image download 命令
        result = subprocess.run(
            ['tapd', 'image', 'download', str(img_id), '--output', out_dir],
            capture_output=True, text=True, timeout=30
        )
        local_path = os.path.join(out_dir, img_name)
        if os.path.exists(local_path):
            downloaded.append(local_path)
        continue

    # 直接下载
    dest = os.path.join(out_dir, img_name)
    try:
        subprocess.run(['curl', '-sSL', img_url, '-o', dest], check=True, timeout=30)
        if os.path.exists(dest):
            downloaded.append(dest)
    except:
        print(f'WARN: 下载失败 {img_name}')

print(f'images=(\"{chr(34).join(downloaded)}\")')
"

# 检查下载的文件并压缩
COMPRESSED=()
for img in "$OUT_DIR"/*.png "$OUT_DIR"/*.jpg "$OUT_DIR"/*.jpeg "$OUT_DIR"/*.gif 2>/dev/null; do
  [ -f "$img" ] || continue
  size=$(stat -f%z "$img" 2>/dev/null || stat -c%s "$img" 2>/dev/null)
  if [ "$size" -gt 1048576 ]; then
    echo "  🗜️  压缩 $(basename "$img") ($(( size / 1024 ))KB → <500KB)..."
    # macOS 自带的 sips 压缩
    if command -v sips &>/dev/null; then
      sips --resampleWidth 1200 "$img" --out "${img%.*}-compressed.png" &>/dev/null
      mv "${img%.*}-compressed.png" "$img"
    elif command -v ffmpeg &>/dev/null; then
      ffmpeg -i "$img" -vf "scale=1200:-1" -q:v 5 "$img.tmp" -y 2>/dev/null
      mv "$img.tmp" "$img"
    else
      echo "    ⚠️  无压缩工具，保留原尺寸"
    fi
    compressed=("${compressed[@]}" "$img")
  fi
done

echo ""
echo "✅ 完成: ${#downloaded[@]} 张截图"
[ ${#compressed[@]} -gt 0 ] && echo "  压缩: ${#compressed[@]} 张"

# 写入元数据
{
  echo "images=("
  for img in "$OUT_DIR"/*.png "$OUT_DIR"/*.jpg "$OUT_DIR"/*.jpeg 2>/dev/null; do
    [ -f "$img" ] && echo "  \"$img\""
  done
  echo ")"
} > "$OUT_DIR/.meta"
