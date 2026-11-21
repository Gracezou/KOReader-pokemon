# Installing and using the Pokédex plugin

[简体中文](INSTALL.zh-CN.md) · [Project overview](../README.md)

## Install in KOReader

This build targets KOReader 2022.01 or later. Start KOReader on your device and check that you can open a book. If you still need to install KOReader on a Kindle, first check the requirements for your model. [KOReader installation on Kindle](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices)

If you use a custom reading menu, back up `settings/reader_menu_order.lua` first. The plugin writes to this file to add its Poké Ball tab.

1. Quit KOReader completely. If you use USB, open the device storage on your computer. Locate the plugins directory for your device in the table below.
2. Install the plugin from your ZIP and check that the device contains `plugins/pokemon.koplugin/main.lua`.

   - **GitHub source ZIP.** Extract the archive, rename the folder that directly contains `main.lua` to `pokemon.koplugin`, then copy that folder into the plugins directory.
   - **ZIP with `main.lua` at the top level.** Create `plugins/pokemon.koplugin/` on the device. Copy `main.lua`, `_meta.lua`, `pokedex_data.lua`, `appbar.pokemon.svg`, `pokeball.png`, `COPYRIGHT.txt`, and the complete `sprites/` and `deco/` directories from the ZIP into that folder. You can also use this file list to install from a local checkout.

3. KOReader’s built-in font works by default. If you have permission to use the optional typeface, copy your local `fonts/PokemonCute.ttf` to `fonts/` in the KOReader data directory, keeping the filename. See the [third-party notices](../NOTICE.md) for artwork and font rights.
4. Safely eject the device and restart KOReader. Open a book, tap the top of the page, select the Poké Ball tab beside the main menu button, then choose **打开主面板** (Open dashboard). A second route is **Tools → More tools → 宝可梦图鉴 → 打开主面板**.

| Device | Usual plugins directory relative to device storage |
| --- | --- |
| Kindle | `koreader/plugins/` |
| Kobo | `.adds/koreader/plugins/`. Enable hidden files in your file manager to see `.adds`. |
| Android | `koreader/plugins/` in internal storage. The enclosing `koreader/` folder usually contains `settings.reader.lua`. |

**If Android uses a different folder**, open **Help → Bug report** in KOReader, export the log and search for `Looking for plugins in directory`. Use a writable location listed there. Once you have identified the KOReader data directory, create its `plugins/` folder if needed. After copying, reopen the destination in your file manager and check for `pokemon.koplugin/main.lua`. [KOReader log instructions](https://github.com/koreader/koreader/wiki/Report-a-bug) · [KOReader plugin loader](https://github.com/koreader/koreader/blob/master/frontend/pluginloader.lua)

## Make your first catch

1. In the dashboard, select **每日目标** (Daily goal). The default is 30 minutes. Choose a target between 5 and 120 minutes in five-minute steps, then tap **保存** (Save).
2. Return to your book. The plugin checks reading time every 20 seconds, adds up time across books for the day, and pauses while the device is suspended. A catch card appears when you reach the goal. You can earn this catch once per day.
3. Open **我的图鉴** (My Pokédex) and filter by generation or catch status. The collection covers 1,025 species across nine generations. Uncaught species appear as silhouettes. For direct access to the Pokédex, assign **宝可梦图鉴** to a KOReader gesture.

The plugin UI and species names are in Simplified Chinese. The plugin runs offline. The dashboard and Pokédex title show the build tag, currently `1027z8`. This build has debugging tools turned off.

## Collection and rewards

| Activity | What happens |
| --- | --- |
| Encounters and evolution | Each uncaught species has a weight of 30 (common), 14 (uncommon), 6 (rare) or 1 (legendary). You can also meet a species again. On the third encounter, a species with an evolution can evolve. You choose the branch when there are multiple options. |
| Shiny Pokémon and partners | The base shiny chance is 1 in 96, rising to 1 in 84 at three hearts and 1 in 72 at five hearts with your partner. A run without a shiny ends by the 200th catch. With at least four hearts, a regular catch that starts the day’s encounters guarantees a new species while any remain. |
| Eggs and candy | An egg advances each day you meet your goal. After three qualifying days, it hatches into a new species while any remain. Spend candy from catches in **糖果罐** (Candy jar) on incense, faster hatching, extra catches or a partner rename card. |
| Finishing a book | When KOReader reports at least 99% progress, you earn 300 XP, 20 candy, one incense and an extra catch, once per book file path. The catch draws from uncaught rare or legendary species first. |
| Long-term goals | Earn eight trainer titles on your way to level 30, with an extra catch at each multiple of five. The plugin selects three daily quests from ten possibilities across different categories and offers a weekly goal. Ten reading badges span 5 to 400 cumulative hours. Collection milestones, daily goal streaks, consecutive new catches and completed regional Pokédexes earn a total of 28 medals. |

## Saves and troubleshooting

- **Updating or moving devices.** Quit KOReader, back up `settings/pokemon.lua` from its data directory, then update `plugins/pokemon.koplugin/` and restart. To move your progress, copy the save to `settings/` on the new device while KOReader is closed on both devices. Saves contain book titles, paths and reading history. Remove personal information from any public bug report.
- **Restoring progress.** In the Poké Ball tab, open **存档管理** (Save manager) to make a backup or select one to restore. The plugin rotates up to three copies, `settings/pokemon_bak1.lua` through `settings/pokemon_bak3.lua`. Confirming a restore overwrites your current progress with the selected copy.
- **Missing plugin or unresponsive panel.** Quit and relaunch KOReader. Check that **宝可梦图鉴** is enabled in plugin management and that `plugins/pokemon.koplugin/main.lua` has no extra enclosing folder. If only the tab is missing, open the plugin from **Tools → More tools**.
- **Missing artwork.** A silhouette marks an uncaught species. Monochrome displays show artwork in grayscale. For blank cells, check that the local artwork, silhouettes and thumbnails were copied, including `plugins/pokemon.koplugin/sprites/sil/small/0001.png`. To close a catch card after the reveal, tap outside it or press the device’s Back key.
- **Clock warning.** A drained battery can reset the device clock. If the clock goes backward, the plugin temporarily uses the last recorded date for daily rewards. Correct the system date and time, then restart KOReader.
- **Uninstalling.** Quit KOReader and move `plugins/pokemon.koplugin/` out of the plugins directory. Keep `settings/pokemon.lua` and the backups to retain progress. To restore a previous custom menu, put your saved `settings/reader_menu_order.lua` back after removing the plugin. The menu icon copied by the plugin resides at `icons/appbar.pokemon.svg`.
