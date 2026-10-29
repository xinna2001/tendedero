# ClipLine · 图绳

Mac 截图与可编辑便签的桌面挂绳。基于 [Tendedero v1.6.1](https://github.com/alejandrobujan/tendedero) 独立修改，使用自己的名称和图标，当前版本 **1.8.0**。

## 文字便签

- 展开挂绳，点击右侧的空夹子，出现一张可直接填写的纸张。
- 输入后自动保存；双击卡片继续编辑，单击复制完整文字。
- 保留换行、缩进与 Unicode；重启后保留内容。
- 普通文字复制粘贴不会自动挂卡，没有文字剪贴板收集器。
- 便签拖出时提供纯文字和 TXT 副本，内部存储格式不出现在普通使用流程。
- 便签右上角常驻小垃圾桶，点一下移到废纸篓；可从废纸篓恢复。
- 只保留顶部回形针入口，Dock 不显示图标；点回形针菜单中的“退出图绳”退出。
- Command+V 和编辑菜单可粘贴文字；编辑窗口也有粘贴按钮。

## 图层与快捷键

- 最前面的金属夹子“新建图层”创建空图层并切换过去；末尾空夹子给当前层新建便签。
- 每层独立保存图片、便签与顺序；旧版已经挂着的内容自动迁移到第一层“日常”。
- 夹子下显示当前层名称及位置；顶部回形针菜单可直接选层和重命名。
- 重启后恢复所有图层及当前层；默认保留全部卡片，超出屏幕宽度可横向滚动。

| 操作 | 按键 |
|---|---|
| 框选截图 | macOS 原有 Command+Shift+4 |
| 整屏截图 / 系统截图工具栏 | Command+Shift+3 / Command+Shift+5 |
| 展示 / 收起挂绳 | Caps Lock+Shift |
| 循环切换图层 | Shift+↓ |

两层时 1→2→1，三层时 1→2→3→1。Shift+↓在便签编辑期间暂时释放，保留系统文字选中行为。Caps Lock+Shift只读取修饰键状态：按住Shift再按Caps Lock，或在Caps Lock已开启时按Shift，每次松开Shift后才能再次触发。

截图继续由macOS完成，图绳监听截图保存目录并把新截图挂到当前层。不再注册Shift+Z，也不提供重复的自定义截图或截图授权入口。长按图片进入系统“标记”；双击用“预览”打开。

## 取下与废纸篓

- 所有卡片的叉号和“取下”只从当前图层移除，源文件保留；“全部取下”同样保留文件。
- 便签右上角垃圾桶把本机这份便签文件移到系统废纸篓，可恢复；原文档和已导出的TXT不受影响。
- 图片右键“移到废纸篓”删除应用目录里的图片；对外部图片，菜单明确写成“将原文件移到废纸篓”。拖到系统废纸篓同样处理对应文件。
- 取下的便签文件不会在重启时自动重新挂回；它保留在本机便签目录中。

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
