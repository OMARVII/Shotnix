# Shotnix localization glossary

Shotnix is translated into German (de), French (fr), and Simplified Chinese
(zh-Hans). Use the words macOS itself uses, so Shotnix reads like part of the
system. When a term isn't here, look at how Apple's own apps say it.

## How it works

- Code: every user-visible string goes through `L("…")`. English is the key.
  Interpolations become placeholders: `L("\(count) captures")` → key
  `%lld captures`; `L("Saved to \(folder)")` → `Saved to %@`.
- Translations: `Localization/translations/<area>.json` (see
  `scripts/localize.py` for the format, including plurals).
- `python3 scripts/localize.py` extracts the keys, merges the translations
  into `Localization/Localizable.xcstrings`, and compiles the `.lproj` files.
  `--check` must pass before anything ships.
- When a folder of `Sources/ShotnixCore` is fully converted, add an empty
  marker file `Localization/areas/<Folder>`: a test then fails on any raw
  user-visible string there (mark a deliberate exception `// l10n-ignore`).
- SwiftUI: write `Text(L("…"))`, `Button(L("…"))`, `.help(L("…"))`, so
  strings resolve through the same bundle in tests and snapshots.
- Never build a sentence from pieces (`"Saved to " + folder`): word order
  differs between languages. Use one string with placeholders.
- Keep every placeholder (`%@`, `%lld`, `%.1f`). To reorder, number them
  (`%1$@`, `%2$@`). A plural needs an `other` form; Chinese has only `other`.

## Style

| | German | French | Simplified Chinese |
|---|---|---|---|
| Address | informal **du** | **vous** | **你** |
| Punctuation | „Anführungszeichen“, `…` | « guillemets » with no-break spaces; a no-break space (U+00A0) before `? ! : ;` | full-width `，。？！：（）`; “引号” |
| Spacing | — | — | a space between Chinese and Latin letters or numbers (`导出 GIF`, `3 张截屏`), none next to full-width punctuation |
| Buttons | short verbs, infinitive (`Sichern`, `Abbrechen`) | infinitive (`Enregistrer`, `Annuler`) | two to four characters where possible (`存储`, `取消`) |

German runs about 30% longer than English: prefer the shorter wording in
buttons and toolbars. French spacing is applied by `scripts/localize.py`
(a no-break space before `? ! : ;` and inside « »), so type ordinary spaces.

Never translate: Shotnix, macOS, Mac, GIF, MP4, HEVC, PNG, JPEG, WebP, OCR,
QR, fps, keyboard symbols (⌘ ⇧ ⌥ ⌃ ⎋ ↩), and file names.

## Terms

| English | German | French | Simplified Chinese |
|---|---|---|---|
| screenshot | Bildschirmfoto | capture d’écran | 截屏 |
| capture (noun, an item in History) | Bildschirmfoto | capture | 截屏 |
| capture (verb, a screenshot) | aufnehmen | capturer | 捕捉 |
| screen recording (the feature) | Bildschirmaufnahme | enregistrement de l’écran | 屏幕录制 |
| recording (a file) | Aufnahme | enregistrement | 录制内容 |
| Capture Area / Record Area | Bereich aufnehmen / Bereich aufzeichnen | Capturer une zone / Enregistrer une zone | 捕捉区域 / 录制区域 |
| record (verb, video) | aufzeichnen (never aufnehmen: that's a screenshot) | enregistrer | 录制 |
| area | Bereich | zone | 区域 |
| window | Fenster | fenêtre | 窗口 |
| full screen | Vollbild | plein écran | 全屏 |
| all displays | alle Bildschirme | tous les écrans | 所有显示器 |
| previous area | vorheriger Bereich | zone précédente | 上一个区域 |
| timed capture | Aufnahme mit Timer | capture avec minuteur | 定时截屏 |
| scrolling capture | Scroll-Aufnahme | capture défilante | 滚动截屏 |
| Capture Text (OCR) | Text erfassen | Capturer du texte | 提取文字 |
| text recognition | Texterkennung | reconnaissance de texte | 文字识别 |
| QR code | QR-Code | code QR | 二维码 |
| pin (a screenshot) | anheften | épingler | 贴到屏幕 |
| pinned screenshot | angeheftetes Bildschirmfoto | capture épinglée | 贴图 |
| screenshot editor | Bildschirmfoto-Editor | éditeur de captures | 截屏编辑器 |
| annotate / annotation | beschriften / Beschriftung | annoter / annotation | 标注 |
| arrow | Pfeil | flèche | 箭头 |
| rectangle / filled rectangle | Rechteck / gefülltes Rechteck | rectangle / rectangle plein | 矩形 / 实心矩形 |
| ellipse | Ellipse | ellipse | 椭圆 |
| line | Linie | ligne | 直线 |
| freehand | Freihand | main levée | 手绘 |
| text | Text | texte | 文字 |
| callout | Sprechblase | bulle | 标注气泡 |
| numbered step | nummerierter Schritt | étape numérotée | 编号步骤 |
| highlighter | Textmarker | surligneur | 荧光笔 |
| blur | weichzeichnen | flouter | 模糊 |
| pixelate | verpixeln | pixéliser | 像素化 |
| spotlight (tool) | Fokus | projecteur | 聚光灯 |
| crop | beschneiden | rogner | 裁剪 |
| background (backdrop) | Hintergrund | arrière-plan | 背景 |
| undo / redo | Widerrufen / Wiederholen | Annuler / Rétablir | 撤销 / 重做 |
| copy / paste | Kopieren / Einsetzen | Copier / Coller | 拷贝 / 粘贴 |
| cut | Ausschneiden | Couper | 剪切 |
| select all | Alles auswählen | Tout sélectionner | 全选 |
| save / save as… | Sichern / Sichern unter … | Enregistrer / Enregistrer sous… | 存储 / 存储为… |
| export | Exportieren | Exporter | 导出 |
| cancel | Abbrechen | Annuler | 取消 |
| delete | Löschen | Supprimer | 删除 |
| done | Fertig | Terminé | 完成 |
| close window | Fenster schließen | Fermer la fenêtre | 关闭窗口 |
| quit Shotnix | Shotnix beenden | Quitter Shotnix | 退出 Shotnix |
| settings | Einstellungen | Réglages | 设置 |
| History | Verlauf | Historique | 历史记录 |
| menu bar | Menüleiste | barre des menus | 菜单栏 |
| keyboard shortcut | Tastaturkurzbefehl (short: Kurzbefehl) | raccourci clavier | 快捷键 |
| microphone | Mikrofon | micro | 麦克风 |
| camera | Kamera | caméra | 摄像头 |
| system audio / computer sound | Systemton | son de l’ordinateur | 电脑声音 |
| voice | Stimme | voix | 人声 |
| pause / resume | Pausieren / Fortsetzen | Pause / Reprendre | 暂停 / 继续 |
| discard (a take) | Verwerfen | Supprimer | 丢弃 |
| countdown | Countdown | compte à rebours | 倒计时 |
| video editor | Video-Editor | éditeur vidéo | 视频编辑器 |
| timeline | Zeitleiste | timeline | 时间线 |
| clip | Clip | clip | 片段 |
| zoom (noun) | Zoom | zoom | 缩放 |
| pointer / cursor | Zeiger | pointeur | 指针 |
| click (noun / verb) | Klick / klicken | clic / cliquer | 点按 |
| captions | Untertitel | sous-titres | 字幕 |
| transcript | Transkript | transcription | 文字稿 |
| music | Musik | musique | 音乐 |
| title card | Titelkarte | carton de titre | 标题卡 |
| transition | Übergang | transition | 转场 |
| drag | ziehen | faire glisser | 拖移 |
| permission (privacy) | Berechtigung | autorisation | 权限 |
| update | Update | mise à jour | 更新 |
