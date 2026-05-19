---
name: tapd-retro
description: "TAPD 批量回顾 — 拉取本周 bug、AI 分析、输出 Markdown 报告"
---

# /tapd-retro — TAPD 批量回顾

## 用法

```
/tapd-retro                   ← 默认：本周 7 天
/tapd-retro --days 14         ← 14 天
/tapd-retro --workspace 12345 ← 指定工作区
```

## 前置条件

```bash
# TAPD 登录
tapd auth login --access-token <token>

# 环境变量
export OPENAI_API_KEY="sk-..."
export OPENAI_BASE_URL="http://8.134.137.112:3001/v1"
export OPENAI_MODEL="gpt-5.4-mini"
```

## 流程

1. 调 `tapd bug list --status=resolved` 拉取本周已解决的 bug
2. 逐个下载截图，超过 1MB 自动压缩
3. 调 GPT vision 分析 bug 描述 + 截图，输出结构化的 JSON
4. 按严重级别汇总为 Markdown 报告

## 示例

```bash
# 在 tapd-ai-cli 项目根目录运行
cd /path/to/tapd-ai-cli
bash scripts/tapd-retro.sh --days 7

# 查看报告
cat docs/bug-reports/$(date +%Y-%m-%d).md
```

```bash
# 输出到指定目录
bash scripts/tapd-retro.sh --days 14 --output ~/retro-reports
```

## 输出示例

```markdown
# Bug 回顾报告 · 2026-05-14 ~ 2026-05-20

## P0 · 点击保存按钮后页面白屏
**版本:** v2.3.1 | **模块:** 编辑页

**复现步骤:**
1. 登录系统
2. 打开编辑页
3. 点击保存按钮
4. 页面白屏

| 期望 | 实际 |
|------|------|
| 保存成功并跳转 | 页面白屏，控制台报错 |
```
