# ClipLine · 图绳

Mac 截图与可编辑便签的桌面挂绳。基于 [Tendedero v1.6.1](https://github.com/alejandrobujan/tendedero) 独立修改，使用自己的名称和图标，当前版本 **1.7.2**。

## 文字便签

- 展开挂绳，点击右侧的空夹子，出现一张可直接填写的纸张。
- 输入后自动保存；双击卡片继续编辑，单击复制完整文字。
- 保留换行、缩进与 Unicode；重启后保留内容。
- 普通文字复制粘贴不会自动挂卡，没有文字剪贴板收集器。
- 便签拖出时提供纯文字和 TXT 副本，内部存储格式不出现在普通使用流程。
- 便签右上角常驻小垃圾桶，点一下移到废纸篓；可从废纸篓恢复。
- Dock 显示图绳图标，点击打开挂绳，右键图标或应用菜单可退出。
- Command+V 和编辑菜单可粘贴文字；编辑窗口也有粘贴按钮。

## 快捷键

| 操作 | 按键 |
|---|---|
| 框选截图 | Shift+Z |
| 展示 / 收起挂绳 | Caps Lock+Shift |

Shift+Z 通过 macOS 全局快捷键注册，不需要辅助功能权限。Caps Lock+Shift 只读取修饰键状态：按住 Shift 再按 Caps Lock，或在 Caps Lock 已开启时按 Shift，每次松开 Shift 后才能再次触发。

应用菜单提供框选截图和“截图权限…”入口。截图本身需要在 **系统设置 → 隐私与安全性 → 屏幕与系统音频录制 / 屏幕录制**允许 ClipLine。没有权限时会明确提示；Cmd+Shift+4 仍可用于系统框选截图，图绳会监听截图保存目录。Esc 取消框选不会生成卡片。

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
