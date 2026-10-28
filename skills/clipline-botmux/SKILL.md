---
name: clipline-botmux
description: 把飞书消息挂成 Mac 图绳的可编辑文字便签，打开或收起挂绳、读回和修改便签，并在应用缺失时从 xinna2001/tendedero 下载校验并本地安装 ClipLine。用户说“图绳”后附文字、“图绳挂上去”、“把这段挂到图绳”、“图绳便签”时使用；用户单独说“图绳”后，同一话题同一发起人接着发送待挂文字时也使用。仅收集用户明确指定的内容，不监听文字剪贴板。
---

# 图绳与 Botmux 联动

用 `scripts/clipline.py` 与独立 Mac 应用 ClipLine 交互。应用存储在 `~/Applications/ClipLine.app`；数据在 `~/Library/Application Support/ClipLine`。仓库为 https://github.com/xinna2001/tendedero ，版本 1.7.1 起支持联动。

## 挂文字

识别用户明确指定的文字，去掉“图绳”指令前缀，保留正文的换行、缩进、标点和字面量。通过 UTF-8 文件或 quoted heredoc 输入；不要把用户正文拼成 shell 命令。使用本条飞书 message ID 作 `--request-id`，重复执行保持同一个 ID。

```bash
python3 scripts/clipline.py hang --request-id MESSAGE_ID <<'NOTE'
需要挂上去的原文
NOTE
```

也可传 `--content-file /absolute/note.txt`。脚本自动安装缺失应用、启动应用、发本机请求、等待应用回执，并读回便签验证全文。只在返回 `success:true` 且 `verified:true` 时回复“已挂上”；说明便签可双击编辑、自动保存。失败时报告精确错误，不重复发送不同 ID 的请求。

## 单独说图绳，再发下一条

从当前 Botmux 上下文取 session ID 和发起人 open_id。单独说“图绳”时执行：

```bash
python3 scripts/clipline.py arm --session SESSION_ID --sender OPEN_ID
```

只把同一话题、同一发起人的下一条明确待挂正文交给 `consume`；保留正文原样，通过 UTF-8 文件输入：

```bash
python3 scripts/clipline.py consume --session SESSION_ID --sender OPEN_ID --request-id MESSAGE_ID --content-file /absolute/note.txt
```

等待状态十分钟后过期。取消时执行 `cancel --session SESSION_ID --sender OPEN_ID`。不要消费其他人、其他话题的消息或机器人输出；用户继续讨论功能而非提供正文时保持正常对话。

## 查看、修改、显示

- 执行 `list` 读取本地便签 ID、正文和 revision。只向用户展示其要求的内容。
- 修改时执行 `update --note-id UUID --revision CURRENT_REVISION --request-id MESSAGE_ID --content-file /absolute/note.txt`。版本冲突时先读回，不覆盖人工编辑。
- 执行 `show` / `hide` 展示或收起挂绳。
- 执行 `status` 查看运行版本、联动协议和快捷键权限状态。

## 安装与权限

第一次缺少应用时，脚本从自有 GitHub 正式 Release 获取 `ClipLine-*-macos-universal.zip`，验证 SHA-256 和应用身份后安装。没有对应 Release 时从自有 `v1.7.1` 标签构建。不要替换上游 Tendedero，也不要清理便签目录。已有旧包需要更新时先正常退出并保留旧包。

Q+A 框选截图、Shift+Q+A 展示/收起需要系统允许 ClipLine 的辅助功能；截图还需要屏幕录制权限。读取 `status` 的实际结果，权限缺失时说明系统设置中的具体开关，不声称快捷键已生效。不要修改 macOS TCC 数据库或代替用户授予系统权限。

## 隔离验证

开发验证可传 `--app /path/ClipLine.app --data-root /tmp/isolated-root`。该目录用于独立便签和回执，避免混入用户真实便签。`--install-root /tmp/isolated-apps` 可验证缺失应用的下载安装；`install --source-app /path/ClipLine.app` 可安装本机已构建的包。

在 Botmux 中用 `botmux send --response-kind final --mention-back` 返回实质结果；同一轮只发一次 final。
