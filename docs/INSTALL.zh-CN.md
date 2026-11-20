# 宝可梦图鉴安装与使用指南

[English](INSTALL.md) · [项目首页](../README.zh-CN.md)

## 安装到 KOReader

此构建面向 KOReader 2022.01 及以上版本。先在设备上启动一次 KOReader，确认能正常打开书籍。如果 Kindle 还没安装 KOReader，请先查看对应机型的安装条件。[KOReader 官方 Kindle 安装说明](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices)

若你自定义过阅读菜单，请在安装前备份 `settings/reader_menu_order.lua`。插件启动时会写入这个文件，把精灵球标签加入阅读菜单。

1. 完全退出 KOReader。使用 USB 传输时，在电脑上打开设备存储，找到下表中的插件目录。
2. 将整个 `pokemon.koplugin/` 复制进去。如果下载的是仓库 ZIP，先解压，只复制其中的插件目录。复制完成后确认设备上有 `plugins/pokemon.koplugin/main.lua`，同一层还能看到 `_meta.lua` 和 `pokedex_data.lua`。图鉴和主面板会从插件目录读取本地图像，使用时请保留素材的子目录结构。
3. 可直接使用 KOReader 的默认字体。如果你有权使用可选字体，可将本地的 `fonts/PokemonCute.ttf` 复制到 KOReader 数据目录的 `fonts/` 下，保留文件名。素材与字体的权利信息见[第三方声明](../NOTICE.zh-CN.md)。
4. 安全弹出设备并重启 KOReader。打开一本书，轻点页面顶部，在主菜单按钮旁打开精灵球标签，选择「打开主面板」。也可以走「工具 → 更多工具 → 宝可梦图鉴 → 打开主面板」。

| 设备 | 常见插件目录（相对于设备存储根目录） |
| --- | --- |
| Kindle | `koreader/plugins/` |
| Kobo | `.adds/koreader/plugins/`。如找不到 `.adds`，请让文件管理器显示隐藏文件。 |
| Android | 内部存储中的 `koreader/plugins/`。通常能在其上一级看到 `settings.reader.lua`。 |

**Android 路径不同怎么办？** 如果是厂商定制版或改过插件路径，打开 KOReader 的「帮助 → 报告错误」导出日志，搜索 `Looking for plugins in directory`，使用日志中列出的可写目录。确认目录后，若缺少 `plugins/`，可在 KOReader 数据目录中创建它。复制后用文件管理器重新打开目标目录，确认能看到 `pokemon.koplugin/main.lua`。[KOReader 日志导出说明](https://github.com/koreader/koreader/wiki/Report-a-bug) · [KOReader 插件加载逻辑](https://github.com/koreader/koreader/blob/master/frontend/pluginloader.lua)

## 第一次捕获

1. 在主面板选择「每日目标」。默认是 30 分钟，可按 5 分钟一档调到 5～120 分钟，轻点「保存」。
2. 回到书中继续阅读。插件每 20 秒检查一次，在当天各本书之间累计时间，休眠时暂停。达到目标后会出现捕获卡，每天有一次这样的基础捕获。
3. 在「我的图鉴」按世代或捕获状态筛选。从 9 个世代的 1,025 只宝可梦中，尚未捕获的以剪影显示。想用手势直接翻图鉴，可在 KOReader 的手势管理中绑定「宝可梦图鉴」。

当前构建标记为 `1027z8`，可在主面板或图鉴标题中核对。此构建默认关闭调试工具。插件界面和图鉴名称使用简体中文，可离线使用。

## 收集玩法

| 玩法 | 规则 |
| --- | --- |
| 相遇与进化 | 未捕获的每只宝可梦按稀有度加权，常见、少见、稀有、传说的权重依次为 30、14、6、1。也可能再遇已捕获的宝可梦。有进化形态的宝可梦相遇满 3 次即可进化，有多个分支时由你选择。 |
| 闪光与伙伴 | 基础闪光概率是 1/96，伙伴好感达到 3 心和 5 心时分别为 1/84 和 1/72。若一直未遇闪光，第 200 次捕获必出。好感达到 4 心时，若当天的第一次相遇是普通捕获，且还有未捕获的宝可梦，这次必定遇到新伙伴。 |
| 孵蛋与糖果 | 每达标一天，蛋前进一步。累计 3 个达标日即可孵化，只要图鉴中还有空位，就能获得新伙伴。捕获得到的糖果可在「糖果罐」兑换熏香、孵化加速、额外捕获或改名卡。 |
| 读完一本书 | 当 KOReader 记录的进度达到 99%，该文件路径首次触发奖励，获得 300 XP、20 糖果、1 份熏香和一次额外捕获。优先抽取未捕获的稀有或传说宝可梦。 |
| 长期目标 | 训练家最高 30 级，共 8 个称号，每升到 5 的倍数级可额外捕获一次。每天从 10 项委托中按不同类别选 3 项，另有每周目标。累计阅读可从 5 小时到 400 小时陆续获得 10 枚阅读徽章，收集数量、连续达标、连续捕新和完成世代图鉴可获得共 28 枚奖章。 |

## 存档与常见问题

- **升级或换设备。** 完全退出 KOReader，备份数据目录里的 `settings/pokemon.lua`，再更新 `plugins/pokemon.koplugin/` 并重启。换设备时，在两边 KOReader 均已退出的情况下，将存档复制到新设备对应的 `settings/` 目录。存档含读过的书名、路径和阅读记录，公开反馈时请隐去个人信息。
- **恢复进度。** 可在精灵球标签的「存档管理」中立即备份或选择要恢复的记录。插件最多轮换保留 3 份 `settings/pokemon_bak1.lua` 至 `settings/pokemon_bak3.lua`。确认恢复会用所选备份覆盖当前进度。
- **找不到插件或界面没有响应。** 完全退出并重新打开 KOReader。在插件管理中确认已启用「宝可梦图鉴」，并检查 `plugins/pokemon.koplugin/main.lua` 之间有没有多套一层文件夹。如果只有顶部标签没出现，可以用「工具 → 更多工具」进入。
- **看不到宝可梦图片。** 剪影表示尚未捕获，黑白屏会以灰阶显示。若整张图格空白，请核对本地立绘、剪影和缩略图是否齐全，例如 `pokemon.koplugin/sprites/sil/small/0001.png`。捕获卡揭晓后，轻点卡片外侧或按设备返回键即可关闭。
- **设备时钟异常。** 电量耗尽等情况可能让时钟倒退，插件会暂时沿用最后记录的日期结算。校准系统日期和时间后重启 KOReader。
- **卸载。** 退出 KOReader 后移出 `plugins/pokemon.koplugin/`。要保留进度，请保留 `settings/pokemon.lua` 和备份文件。如需恢复原有自定义菜单，此时放回安装前备份的 `settings/reader_menu_order.lua`。插件复制到 KOReader 的图标位于 `icons/appbar.pokemon.svg`。
