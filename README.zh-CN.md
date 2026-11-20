<h1 align="center">宝可梦图鉴 · KOReader 阅读激励插件</h1>

<p align="center">在 KOReader 里读满当天的目标时长，就会在书页间遇见一只宝可梦。</p>

<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong> ·
  <a href="docs/INSTALL.zh-CN.md">安装指南</a> · <a href="#作者">作者主页</a> ·
  <a href="LICENSE">原创代码（MIT）</a> · <a href="NOTICE.zh-CN.md">素材权利</a>
</p>

<p align="center">
  <img src="pokemon.koplugin/sprites/sil/0054.png" width="84" alt="未捕获的可达鸭剪影">
  <img src="pokemon.koplugin/sprites/0054.png" width="84" alt="黄色的普通可达鸭">
  <img src="pokemon.koplugin/sprites/shiny/0054.png" width="84" alt="浅蓝色的闪光可达鸭">
  <br>
  <sub>图鉴 #0054 · 可达鸭｜未捕获的剪影、普通形态与闪光形态</sub>
</p>

## 遇见你的第一只宝可梦

1. **安装插件。** 完全退出 KOReader，把整个 `pokemon.koplugin/` 文件夹复制到它的 `plugins/` 目录。复制后应能找到 `plugins/pokemon.koplugin/main.lua`。插件可直接使用 KOReader 内置字体。
2. **打开图鉴。** 重启 KOReader，打开一本书，轻点页面顶部。点精灵球标签 **宝可梦图鉴 → 打开主面板**，也可以从 **工具 → 更多工具 → 宝可梦图鉴** 进入。
3. **设置每日目标。** 默认每天 **30 分钟**，可在 **5～120 分钟**之间调整。只要书籍打开且 KOReader 处于唤醒状态，阅读时间就会累计，达标后会出现捕获卡。

Kindle、Kobo 和 Android 的安装路径、更新、备份与常见问题，见[安装与排障指南](docs/INSTALL.zh-CN.md)。

## 把阅读进度收进图鉴

| 阅读与收集 | 在插件里会发生什么 |
| --- | --- |
| 每日阅读达标 | 每天获得一次基础捕获，每次捕获都有机会遇到闪光个体。累计三个达标日，蛋里的宝可梦就会孵出来。 |
| 再次相遇 | 有进化形态的宝可梦在第三次相遇时可以进化。遇到伊布等有多个进化方向的宝可梦时，由你选择分支。 |
| 伙伴陪读 | 选一只伙伴积累好感，攒糖果、做每日委托。读完一本书还能获得经验、糖果、熏香和一次额外相遇。 |
| 翻看收藏 | 离线图鉴收录九个世代、共 **1,025 种**宝可梦，可按世代或捕获状态筛选。菜单和宝可梦名称均为简体中文。 |

## 作者

插件由 **萧涵瑾** 开发和维护。

[小红书 · @吱了个吱吱](https://xhslink.cn/o/7J3Y9htj3Sh)　·　[抖音主页](https://v.douyin.com/vbHDGfxZBZc/)　·　[B 站 · 吱了个吱吱-](https://b23.tv/vxks3K5)

## 反馈问题

反馈时请附上设备型号、KOReader 版本、主面板显示的构建标记和复现步骤。存档 `settings/pokemon.lua` 及其备份可能包含书名和完整文件路径，请在分享前隐去这些信息。[项目 Issues](https://github.com/Gracezou/kindle-pokemon/issues)

## 版权与许可

这是免费提供、不以营利为目的的非官方同人插件。阅读计时、捕获奖励和图鉴界面的原创代码及项目原创文档 © 2026 萧涵瑾，采用 MIT 许可证。[MIT 许可证](LICENSE)

上方展示的可达鸭与图鉴立绘均取自 PokéAPI 的素材集，其声明将图像版权归于 The Pokémon Company。宝可梦名称、角色形象和商标的权利归各自权利人。免费开源本身不授予使用或再分发这些素材的权利。[第三方素材与版权说明](NOTICE.zh-CN.md)

设备上可在 **宝可梦图鉴 → 玩法说明** 查看署名与版权摘要。分发原创代码的副本或实质性部分时，请随附版权声明和许可声明。插件目录中的[离线版权说明与 MIT 许可全文](pokemon.koplugin/COPYRIGHT.txt)已包含两者。
