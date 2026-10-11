# Shotnix localization glossary

Shotnix is translated into German (de), French (fr), Simplified Chinese
(zh-Hans), Russian (ru), Ukrainian (uk), and Japanese (ja). Use the words macOS itself uses, so Shotnix reads like part of the
system. When a term isn't here, look at how Apple's own apps say it.

## How it works

- Code: every user-visible string goes through `L("…")`. English is the key.
  Interpolations become placeholders: `L("\(count) captures")` → key
  `%lld captures`; `L("Saved to \(folder)")` → `Saved to %@`.
- Translations: `Localization/translations/<area>.json` (see
  `scripts/localize.py` for the format, including plurals). A language can
  also live in its own files, `<area>.<language>.json` (`app.ru.json`), with
  entries like `{"Save": {"ru": "Сохранить"}}`: the script merges every file,
  and stops if two files translate one key differently.
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
- A string that changes with a count gets plural forms, and holds exactly one
  integer (`%lld`), which decides the form; other placeholders are fine
  (`Saved %@ in %lld files`). Two counts: split it into two strings.
- Numbers interpolated as `Int` follow the user's locale (1.000 on a German
  Mac; tests use the language they switch to). Pixel sizes and other codes:
  pass `String(value)` to keep digits plain.
- Dates: `formatted(date:time:)` and `Date.FormatStyle` follow the language;
  never a fixed `DateFormatter.dateFormat` in the UI.

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

## macOS names

Copy these exactly when a string sends people somewhere in macOS (they come
from System Settings itself). German puts each name in „…“, Chinese in “…”.

| English | German | French | Simplified Chinese |
|---|---|---|---|
| System Settings | Systemeinstellungen | Réglages Système | 系统设置 |
| Privacy & Security | Datenschutz & Sicherheit | Confidentialité et sécurité | 隐私与安全性 |
| Screen & System Audio Recording | Aufnahme von Bildschirm & Systemaudio | Enregistrement de l’écran et des sons du système | 录屏与系统录音 |
| Screen Recording (macOS 14 and earlier) | Bildschirmaufnahme | Enregistrement de l’écran | 录屏 |
| Microphone / Camera | Mikrofon / Kamera | Micro / Caméra | 麦克风 / 摄像头 |
| Accessibility | Bedienungshilfen | Accessibilité | 辅助功能 |
| Speech Recognition | Spracherkennung | Reconnaissance vocale | 语音识别 |
| Keyboard → Keyboard Shortcuts → Screenshots | Tastatur → Tastaturkurzbefehle → Bildschirmfotos | Clavier → Raccourcis clavier → Captures d’écran | 键盘 → 键盘快捷键 → 截屏 |
| General → Language & Region → Applications | Allgemein → Sprache & Region → Apps | Général → Langue et région → Applications | 通用 → 语言与地区 → 应用程序 |

## Russian and Ukrainian

| | Russian | Ukrainian |
|---|---|---|
| Address | **вы**, lowercase, as Apple does | **ви**, lowercase |
| Buttons and menu items | infinitive (`Сохранить`, `Отменить`) | infinitive (`Зберегти`, `Скасувати`) |
| Quotes | «ёлочки», „лапки“ inside | «ялинки», „лапки“ inside |
| Plurals | `one`, `few`, `many`, `other`: 1 снимок, 2 снимка, 5 снимков; `other` is for fractions | `one`, `few`, `many`, `other`: 1 знімок, 2 знімки, 5 знімків |

Both run about 20% longer than English: keep buttons short. The script
refuses a plural without all four forms. Dashes are spaced em dashes ( — ),
the ellipsis is one character (…), and product names (Shotnix, Mac, macOS,
Finder, GIF, MP4…) stay in Latin letters and aren't declined.

| English | Russian | Ukrainian |
|---|---|---|
| screenshot | снимок экрана (short: снимок) | знімок екрана (short: знімок) |
| capture (verb, a screenshot) | снять | зняти |
| Capture Area / Record Area | Снять область / Записать область | Зняти область / Записати область |
| screen recording (the feature) | запись экрана | запис екрана |
| recording (a file) | запись | запис |
| record (verb, video) | записать | записати |
| area / window / full screen | область / окно / весь экран | область / вікно / весь екран |
| History | История | Історія |
| screenshot editor | редактор снимков | редактор знімків |
| video editor | видеоредактор | відеоредактор |
| annotation | разметка | розмітка |
| arrow / text / callout | стрелка / текст / выноска | стрілка / текст / виноска |
| highlight / highlighter | выделение / маркер | виділення / маркер |
| blur / pixelate | размытие / пикселизация | розмиття / пікселізація |
| crop | обрезать | обрізати |
| background (backdrop) | фон | тло |
| pin (a screenshot) | закрепить на экране | закріпити на екрані |
| text recognition (OCR) | распознавание текста | розпізнавання тексту |
| pointer | указатель | курсор |
| click (verb) | нажать | клацнути |
| drag | перетянуть | перетягнути |
| captions / transcript | субтитры / расшифровка | субтитри / розшифровка |
| timeline / clip | шкала времени / клип | шкала часу / кліп |
| export | экспортировать | експортувати |
| undo / redo | Отменить / Повторить | Відмінити / Повторити |
| copy / paste / cut | Скопировать / Вставить / Вырезать | Скопіювати / Вставити / Вирізати |
| save / save as… | Сохранить / Сохранить как… | Зберегти / Зберегти як… |
| cancel / delete / done | Отменить / Удалить / Готово | Скасувати / Видалити / Готово |
| Show in Finder | Показать в Finder | Показати у Finder |
| quit Shotnix | Завершить Shotnix | Завершити Shotnix |
| settings | Настройки | Параметри |
| menu bar | строка меню | смуга меню |
| keyboard shortcut | сочетание клавиш | клавіатурне скорочення |
| microphone / camera | микрофон / камера | мікрофон / камера |
| system audio | системный звук | системний звук |
| Settings tabs: General, Shortcuts, Screenshots, Recording, About | Основные, Сочетания (short: the tab strip is narrow), Снимки экрана, Запись, О программе | — |
| capture (noun, an item in History) | снимок | — |
| Scrolling Capture / Timed Capture | снимок с прокруткой / снимок с таймером | — |
| Capture Text | Распознать текст | — |
| Quick Access Overlay (the thumbnail after a capture) | миниатюра быстрого доступа (short: миниатюра) | — |
| Command Center | командный центр | — |
| Edit (the menu, and the button that opens the editor) | Правка | — |
| System Default (microphone, camera, language) | Как в системе | — |
| Clean Up (History and video data) / Clear History | Убрать лишнее / Очистить историю | — |
| padding (around a screenshot or video) | отступ | — |
| spotlight (tool) / numbered steps | прожектор / нумерованные шаги | — |
| Undo X / Redo X (edit names) | Отменить / Повторить + noun: Отменить удаление увеличения | — |
| click (noun) | нажатие | — |
| zoom: the tab, lane and tool / one zoom on the timeline / Auto Zoom | Масштаб / увеличение (its bar: Масштаб 2×) / автомасштаб | — |
| playhead | указатель воспроизведения | — |
| cut: a removed part / the join between clips | вырезанный фрагмент / склейка | — |
| intro / outro; intro card / outro card; end card | вступление / концовка; начальный титр / финальный титр; финальная заставка | — |
| fade in / fade out; dissolve / dip to black | нарастание / затухание; растворение / затемнение | — |
| camera bubble / camera layout | окошко камеры / расположение камеры | — |
| filler words (ums) / idle moments | слова-паразиты / простои | — |
| Enhance voice | улучшение голоса | — |
| mute / unmute | выключить звук / включить звук | — |
| preview (in the editor) | предпросмотр | — |
| export (button, tab, section) / Export… | Экспорт / Экспортировать… | — |
| recording quality: Balanced, High, Max | Среднее, Высокое, Максимальное | — |
| px / pt (units) | пикс. / пт | — |
| Settings tabs: General / Shortcuts / Screenshots / Recording / About | — | Загальні / Скорочення / Знімки екрана / Запис / Про програму |
| System Default (language pop-up) | — | Як у системі |
| scrolling capture | — | знімок із прокручуванням |
| timed capture | — | знімок за таймером |
| Capture Text (OCR) | — | Розпізнати текст |
| display (a screen) | — | дисплей |
| Quick Access overlay (the thumbnail) | — | мініатюра |
| spotlight (tool) | — | прожектор |
| Clean Up (History, video data) / Clear History | — | Прибрати / Очистити історію |
| Command Center / Health | — | командний центр / Стан |
| Library (History's sidebar) | — | медіатека |
| click (noun) | — | клацання |
| Zoom (the editor's tab and lane) / a zoom | — | Масштаб / наближення (Auto Zoom: автонаближення) |
| playhead | — | покажчик відтворення |
| lane (timeline) | — | доріжка |
| Style (the editor's tab) | — | Стиль |
| camera bubble / camera layout | — | бульбашка камери / макет камери |
| title card / intro card / outro card / end card | — | заставка / вступна заставка / завершальна заставка / кінцева заставка |
| cut (a removed part) / cut (between clips) | — | вирізаний фрагмент / склейка |
| trim (a clip) | — | підрізати |
| transition: dissolve / dip to black / hard cut | — | розчинення / затемнення / пряма склейка |
| fade in / fade out | — | плавна поява / плавне зникнення |
| transcribe / narration | — | розшифрувати / мовлення |
| filler words (um, uh) | — | слова-паразити |
| idle moments (Speed Up Idle) | — | простої |
| burn in (captions) | — | вшити |
| song (music) | — | трек |
| upload | — | вивантажити |

macOS names, from System Settings on macOS 26:

| English | Russian | Ukrainian |
|---|---|---|
| System Settings | Системные настройки | Системні параметри |
| Privacy & Security | Конфиденциальность и безопасность | Приватність і безпека |
| Screen & System Audio Recording | Запись экрана и системного звука | Записування системного звуку й екрана |
| Screen Recording (macOS 14 and earlier) | Запись экрана | Запис екрана |
| Accessibility | Универсальный доступ | Доступність |
| Speech Recognition | Распознавание речи | Розпізнавання мовлення |
| Keyboard → Keyboard Shortcuts → Screenshots | Клавиатура → Сочетания клавиш → Снимки экрана | Клавіатура → Клавіатурні скорочення → Знімки екрана |
| General → Language & Region → Applications | Основные → Язык и регион → Приложения | Загальні → Мова і регіон → Програми |

## Japanese

Japanese follows Apple's own Japanese, measured from the macOS 26 string
tables (AppKit, Screenshot, Preview, System Settings).

| | Japanese |
|---|---|
| Register | sentences, alerts, help text and descriptions in polite です/ます (`保存しますか?`, `書き出しました。`); no あなた (leave the subject out, as Apple does) |
| Buttons and menu items | a noun or a plain verb, as Apple's menus: `保存`, `キャンセル`, `書き出す…`, `取り消す`, `ウインドウを閉じる`, `Finderに表示` |
| Punctuation | full-width `、。` and `（）`; half-width `?` and `!` (Apple writes `置き換えてもよろしいですか?`); a label colon is half-width with a space after (`最小: 10`) |
| Quotes | names of things in “…” as Apple does (`“システム設定”`), not 「…」 |
| Spacing | no space between Japanese and Latin letters or digits (`Shotnixを終了`, `10秒`, `GIFを書き出す`); keep the spaces inside Latin phrases (`QuickTime Player`) |
| Menu paths | “…”＞“…” in sentences, as Apple's help does (`“システム設定”＞“プライバシーとセキュリティ”`); keep an arrow (→) only where the English key draws one as a symbol |
| Plurals | one form only: give a plain string, like Chinese (`%lld件のスクリーンショット`) |
| Counters | `%lld項目` (selected or deleted items, as Finder says), `%lld件` (captures in History), `%lld個` (zooms, clips, captions), `%lld箇所` (cuts, pauses), `%lld回` (clicks), `%lld秒`, `%lld分`, `%lld枚` (images) |
| Katakana | Apple's spellings without the final long vowel: `ウインドウ` (never ウィンドウ), `フォルダ`, `ポインタ`, `エディタ`, `スライダ`, `サムネール`, `ユーザ`, `フィルタ`, `プレーヤー` |
| Ellipsis | the single character `…`, as in English |

Japanese is often shorter than English, but katakana words grow fast: keep
buttons to a word or two.

| English | Japanese |
|---|---|
| screenshot | スクリーンショット |
| capture (verb, a screenshot) | 取り込む (Apple's Screenshot: `選択部分を取り込む`) |
| capture (noun, an item in History) | スクリーンショット (or 項目 for any kind of item) |
| Capture Area / Capture Window / Capture Fullscreen | 範囲を取り込む / ウインドウを取り込む / 画面全体を取り込む |
| Record Area / Record Window / Record Fullscreen | 範囲を収録 / ウインドウを収録 / 画面全体を収録 |
| screen recording (the feature) | 画面収録 |
| record (verb, video) | 収録する (Apple: `収録を停止`); 録音 only for sound alone |
| recording (a file) | 収録 (or 収録したビデオ where 収録 alone is unclear) |
| area / window / full screen | 範囲 / ウインドウ / 画面全体 |
| all displays / display | すべてのディスプレイ / ディスプレイ |
| previous area | 前回の範囲 |
| scrolling capture | スクロール取り込み (the action: スクロールして取り込む) |
| timed capture | タイマー取り込み (the action: タイマーで取り込む) |
| Capture Text (OCR) / text recognition | テキストを取り込む / テキスト認識 |
| QR code | QRコード |
| pin (a screenshot) / pinned screenshot | 画面に固定 / 固定したスクリーンショット |
| screenshot editor / video editor | スクリーンショットエディタ / ビデオエディタ |
| annotate / annotation | 注釈を付ける / 注釈 |
| arrow / rectangle / filled rectangle / ellipse / line | 矢印 / 長方形 / 塗りつぶした長方形 / 楕円 / 線 |
| freehand / text / callout | フリーハンド / テキスト / 吹き出し |
| numbered step | 番号付きステップ |
| highlight / highlighter | ハイライト / 蛍光ペン |
| blur / pixelate | ぼかし / モザイク |
| spotlight (tool) | スポットライト |
| crop | 切り取り (Apple Preview's word; Cut is カット, so they never clash) |
| background (backdrop) / padding / shadow / corner radius | 背景 / 余白 / シャドウ / 角の丸み |
| opacity | 不透明度 |
| undo / redo | 取り消す / やり直す (an edit's name: `ズームの削除を取り消す`) |
| copy / paste / cut / select all | コピー / ペースト / カット / すべてを選択 |
| save / save as… / don't save | 保存 / 別名で保存… / 保存しない |
| export (button) / Export… / export (noun) | 書き出す / 書き出す… / 書き出し |
| cancel / delete / done / close | キャンセル / 削除 / 完了 / 閉じる |
| Show in Finder | Finderに表示 |
| quit Shotnix / About Shotnix | Shotnixを終了 / Shotnixについて |
| settings / Settings… | 設定 / 設定… |
| Settings tabs: General, Shortcuts, Screenshots, Recording, About | 一般 / ショートカット / スクリーンショット / 収録 / 情報 |
| System Default (microphone, camera, language) | システムのデフォルト |
| History / Library (History's sidebar) | 履歴 / ライブラリ |
| Clean Up / Clear History | クリーンアップ / 履歴を消去 |
| Quick Access overlay (the thumbnail after a capture) | クイックアクセス (the thumbnail itself: サムネール) |
| Command Center / Health | コマンドセンター / 状態 |
| menu bar | メニューバー |
| keyboard shortcut | キーボードショートカット (short: ショートカット) |
| microphone / camera | マイク / カメラ |
| system audio / computer sound | システムオーディオ |
| voice / narration | 声 / ナレーション |
| pause / resume / stop | 一時停止 / 再開 / 停止 |
| discard (a take) | 破棄 |
| countdown | カウントダウン |
| timeline / lane / clip | タイムライン / トラック / クリップ |
| playhead | 再生ヘッド |
| trim / cut (a removed part) / cut (the join) | トリミング / カット / つなぎ目 |
| zoom (noun) / Auto Zoom | ズーム / 自動ズーム |
| pointer / cursor | ポインタ |
| click (noun / verb) | クリック / クリックする |
| drag | ドラッグ |
| captions / burn captions into the video | 字幕 / 字幕をビデオに焼き付ける |
| transcript / transcribe | 文字起こし / 文字起こしする |
| filler words (um, uh) | フィラー (えー、えーと) |
| idle moments (Speed Up Idle) | 動きのない区間 |
| Enhance voice | 声を補正 |
| mute / unmute | 消音 / 消音を解除 |
| volume / speed / aspect ratio | 音量 / 速度 / アスペクト比 |
| music / song | 音楽 / 曲 |
| title card / intro / outro / end card | タイトルカード / オープニング / エンディング / エンドカード |
| transition: dissolve / dip to black / hard cut | トランジション: ディゾルブ / 黒にフェード / カット |
| fade in / fade out | フェードイン / フェードアウト |
| camera bubble / camera layout | カメラのワイプ / カメラのレイアウト |
| vertical (9:16) | 縦型 |
| preview | プレビュー |
| permission (privacy) | アクセス許可 |
| update / Check for Updates… | アップデート / アップデートを確認… |
| px / pt | px / pt |

macOS names, from System Settings on macOS 26:

| English | Japanese |
|---|---|
| System Settings | システム設定 |
| Privacy & Security | プライバシーとセキュリティ |
| Screen & System Audio Recording | 画面収録とシステムオーディオ録音 |
| Screen Recording (macOS 14 and earlier) | 画面収録 |
| Microphone / Camera | マイク / カメラ |
| Accessibility | アクセシビリティ |
| Speech Recognition | 音声認識 |
| Keyboard → Keyboard Shortcuts… → Screenshots | キーボード＞キーボードショートカット…＞スクリーンショット |
| General → Language & Region → Applications | 一般＞言語と地域＞アプリケーション |
| Login Items & Extensions | ログイン項目と機能拡張 |
