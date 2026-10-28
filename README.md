# ClipLine · 图绳

Mac 截图与可编辑便签的桌面挂绳。基于 [Tendedero v1.6.1](https://github.com/alejandrobujan/tendedero) 独立修改，使用自己的名称和图标，当前版本 **1.7.1**。

## 文字便签

- 展开挂绳，点击右侧的空夹子，出现一张可直接填写的纸张。
- 输入后自动保存；双击卡片继续编辑，单击复制完整文字。
- 保留换行、缩进与 Unicode；重启后保留内容。
- 普通文字复制粘贴不会自动挂卡，没有文字剪贴板收集器。
- 便签拖出时提供纯文字和 TXT 副本，内部存储格式不出现在普通使用流程。
- 取下便签保留本地数据；明确移到废纸篓才删除。

## 快捷键

| 操作 | 按键 |
|---|---|
| 框选截图 | 同时按 Q+A |
| 展示 / 收起挂绳 | 同时按 Shift+Q+A |

两字母需要在 220 ms 内按下且按住重叠。Shift 优先选择展示操作，每次完全释放后才能再次触发。普通不重叠的 Q/A 输入和 Command、Control、Option 快捷键继续传递。

应用菜单提供截图、显示、新建便签及快捷键授权入口。首次使用全局键需要在 **系统设置 → 隐私与安全性 → 辅助功能**允许 ClipLine；框选截图还需要允许屏幕录制。系统安全输入模式可能屏蔽全局事件，应用不绕过系统限制。

## Botmux 联动

使用 [clipline-botmux Skill](skills/clipline-botmux/SKILL.md)：

```text
图绳
这周的待办：
1. 核对评测结果
2. 更新交付文档
```

Bot 把明确指定的正文挂成便签，收到应用回执后读回全文验证。也支持单独说“图绳”，再发送同一话题、同一发起人的下一条待挂消息，十分钟内有效。

缺少应用时，Skill 从本仓库 Release 下载并校验安装包，安装到 `~/Applications/ClipLine.app`；没有安装包时从本仓库对应版本标签构建。便签和回执在 `~/Library/Application Support/ClipLine`，不上传网络。

## 安装与构建

下载本仓库 [最新版](https://github.com/xinna2001/tendedero/releases/latest) 的 `ClipLine-*-macos-universal.zip`，解压后放到「应用程序」。支持 macOS 14+、Apple silicon 与 Intel。本地构建包使用本机可用的 Developer ID 或 ad hoc 签名；不声称已经 Apple 公证。

```bash
bash scripts/build-app.sh release
swift run ClipLineCoreChecks
swift scripts/check-strings.swift
```

仅验证本机架构时可以执行 `CLIPLINE_ARCHS=arm64 bash scripts/build-app.sh debug`。Debug 包在独立 `CLIPLINE_DATA_ROOT` 下可用 `--ui-checks` 验证空夹子、实际编辑、复制与持久化，并生成界面截图。Release 不包含该验证入口。

## 来源与许可

源代码 MIT，保留上游版权。上游名称、图标及品牌条款见 [LICENSE](LICENSE)，来源说明见 [NOTICE](NOTICE)。本项目不代表上游作者。

文字卡片交互参考上游 [PR #12](https://github.com/alejandrobujan/tendedero/pull/12)，采用手动新建方式，正文不经由剪贴板自动收集。
