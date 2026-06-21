# Reasonix 通知声音配置

## 文件位置

```
全局: ~/.reasonix/settings.json        ← 所有项目生效
项目: .reasonix/settings.json          ← 仅本项目生效（需 /hooks trust）
```

## 当前配置

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "match": "edit_file|write_file|multi_edit|run_command|run_background|submit_plan",
        "command": "powershell -c \"Add-Type -AssemblyName PresentationCore; $mp=New-Object System.Windows.Media.MediaPlayer; $mp.Open([Uri]'file:///C:/Users/swkgb/Music/intervention.mp3'); $mp.Play(); Start-Sleep 2\""
      }
    ],
    "Stop": [
      {
        "command": "powershell -c \"Add-Type -AssemblyName PresentationCore; $mp=New-Object System.Windows.Media.MediaPlayer; $mp.Open([Uri]'file:///C:/Users/swkgb/Music/complete.mp3'); $mp.Play(); Start-Sleep 1\""
      }
    ]
  }
}
```

## 事件说明

| 事件 | 触发时机 | 当前声音 | 说明 |
|:-----|:---------|:---------|:-----|
| `PreToolUse` | 写入操作前（需审批） | `intervention.mp3` | 人工介入 |
| `Stop` | AI 回复完毕 | `complete.mp3` | 任务结束 |
| `PostToolUse` | 工具执行后 | — | 可选的完成反馈 |
| `UserPromptSubmit` | 你发送消息时 | — | 当前未使用 |

## hook 事件完整列表

```
PreToolUse      — 每次工具调用前（可阻断）
PostToolUse     — 每次工具调用后
UserPromptSubmit — 你发送消息前（可阻断）
Stop            — AI 回复完毕
PostLLMCall     — 模型推理完成后
SessionStart    — 会话开始
SessionEnd      — 会话结束
SubagentStop    — 子 agent 任务完成
Notification    — AI 需要你注意时
PreCompact      — 上下文压缩前
```

## match 正则说明

`PreToolUse` 和 `PostToolUse` 可以用 `match` 过滤特定工具：

```
# 匹配单个工具
"match": "edit_file"

# 匹配多个工具（| 分隔）
"match": "edit_file|write_file|run_command"

# 匹配所有工具（不设 match 或设为 "*"）
"match": "*"
```

## 修改声音文件

1. 把你的 mp3 放到 `C:\Users\swkgb\Music\`
2. 修改 `settings.json` 中的文件路径
3. 重启 Reasonix 终端生效

## 常用命令

```
/hooks          查看当前加载的 hooks
/hooks trust    信任项目 hooks（项目级需要）
/hooks reload   重新加载（仅限当前会话的自动重新发现）
```
