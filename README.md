# dsh-external-toolbox（外部工具箱）

在任意 Windows 程序里选中一段文字 → 光标旁浮出一小条工具条 → 就地翻译，或把原文引用进 DSH 输入框继续提问。
不限于翻译：后续的取词类动作也会挂在这条工具条上。

## 用法

- **不用快捷键**：鼠标拖选 / 双击选词 / Ctrl+A / Shift+方向键选中后，约 0.2 秒弹出小工具条。
- 小工具条只有「翻译 / 提问 / 关闭」。点「翻译」才弹出完整卡片（原文 + 译文 + 复制译文），此时请求才真正发给模型，省 token。
- **Esc** 关闭卡片 / 工具条 / 语言菜单（由低级键盘钩子截获，不会传给下面的程序）。
- 兜底热键 **Ctrl+Alt+Q**（自动弹卡失灵时用）。
- 「提问」会把选区以引用块预填进 DSH 的 composer，并把 DSH 窗口唤到前台。

## 语言

- 默认 **AUTO**：中日韩文本译成英文，其余（英文/西文/数字）译成中文。
- 卡片右上角下拉框可固定目标语言：AUTO / ZH / EN / JA / KO / ES / FR / DE / RU / PT / IT；切换后已有译文会立刻重译。

## 组成

| 文件 | 作用 |
| --- | --- |
| `lib/index.js` | host 半边：注册 `/toolbox/latest`、`/toolbox/translate`、`/toolbox/beat`，拉起 helper 子进程 |
| `lib/client.js` | 浏览器半边：轮询 latest，把选区填进 composer |
| `helper/capture.ps1` | PowerShell 助手：全局鼠标/键盘钩子、UIA 取词、浮窗 UI、激活 DSH |
| `locale/*.json` | 插件市场里显示的标题与描述 |
| `icon.png` | 插件图标 |

## 改代码时注意

- `helper/capture.ps1` **必须保持纯 ASCII**（中文一律用码点：`U 0x5212, 0x8BCD`），否则 PowerShell 5.1 会按 GBK 解析而报语法错。
- 改完 helper 要同时校验两层：`[Parser]::ParseFile($path)` 与 `ParseInput($here-string body)`。
- 改 C# 块后跑一次 `-ActivateTest`，否则只在运行时暴露编译错误。
- 临时测试脚本一律用 ASCII 路径 `D:\Document\deepseek-harness\dsh-select-translate\...`（中文路径在 ASCII 编码保存时会被写成 `????`）。
## "Ask" opens a new session

The browser half looks up the client service `uiWorkspace` (registered by
`@deepseek-ai/dsh-client-ui-workspace`, the same object the sidebar's
`session.new` shortcut calls) and invokes `startSession()`. The quote is then
written into the composer of whatever session the seat re-mounts for.

If that service is missing (other DSH builds), the client falls back to
`history.pushState` on a `/session...` route and, failing that, writes into the
current session's composer. `client apply uiWorkspace=startSession ...` lines in
`%TEMP%\dsh-external-toolbox-host.log` show what the probe found at startup.
## Actions

The pill offers `翻译` / `解释` / `提问`; the card repeats the three plus a copy
button, and the header's language menu picks the target language.

Both text actions hit the same host handler:

```
GET /toolbox/run?id=<captureId>&task=translate|explain&to=<lang>
```

`/toolbox/translate` is kept for older helpers and always means `task=translate`.
`to=auto` means "translate into the opposite language" for `translate`, and
"explain in Chinese" for `explain` (an explanation is for the reader, not for a
language pair). The host answers `{ ok, task, target, auto, text }`.
## Vocabulary book

`收藏` on the card appends the pair to

```
%APPDATA%\dsh-external-toolbox\vocab.jsonl     one JSON object per line
%APPDATA%\dsh-external-toolbox\生词本.md        readable mirror, rebuilt on every save
```

The helper forwards it as a `{"type":"vocab", word, translation, lang, task}` line
on stdout; the host writes the files. The same book is readable over HTTP:

```
GET /toolbox/vocab                          -> { ok, count, file, entries }
GET /toolbox/vocab?word=&translation=&lang= -> { ok, count }   (saves one pair)
```

Saving the same word twice within a minute is treated as a double click and
ignored.

## Reading the translation aloud

The host half is not involved: after a successful `translate` the helper speaks
the result with `System.Speech`. It picks a `zh-` or `en-` voice when the machine
has one and stays silent otherwise (`explain` never speaks). Pass `-NoSpeak` to
the helper for tests.
## Reviewing (spaced repetition)

`生词` on the pill (and in the card header) opens the review window: it shows one
word, you recall the meaning yourself, `看答案` reveals it, then grade it
`忘了 / 模糊 / 记得`. The word is written back with its next due date.

```
GET /toolbox/review                                   -> next due card
GET /toolbox/review?word=<w>&grade=again|hard|good    -> grade it, next card
```

Scheduling keeps three numbers per word (`interval` days, `ease`, `reps`):

| grade | next due | effect |
| --- | --- | --- |
| `again` | +10 minutes | `reps = 0`, `ease - 0.2` |
| `hard` | +1 day | `ease - 0.15` |
| `good` | `reps = 1 → 1d`, `2 → 3d`, else `interval × ease` (max 120d) | `reps + 1` |

Only words whose `due` has passed come up; when nothing is due the window says
so and shows the total. The JSONL stays append-only (the latest record per word
wins), so the file remains diff-able and the Markdown mirror is always the
freshest view.
### Richer entries

Saving a word takes the translation the card already has, then asks the model for
a compact dictionary entry in the background and appends it to the same record:

```
词性: n.
释义: 意外发现美好事物的运气; 机缘巧合
例句: Meeting her was pure serendipity.
译文: 遇见她纯属机缘巧合。
搭配: serendipitous (adj.); by serendipity
```

The review window shows that when you reveal the answer, the Markdown mirror
gets one section per word, and words saved before this existed are backfilled the
first time they come up in review. No model selected means no detail — the card
just keeps the plain translation.

The `文件` button opens the Markdown with notepad: `.md` has no default handler on
many machines, and a silent failure there looked like "the file cannot be opened".
### Picking single words out of a sentence

Select a word inside the source pane and press `收藏`: the helper sends that word
with the full sentence as `context`, so the entry is about the word *as used
there*. With no selection it saves the whole capture, as before.

The review window shows the sentence under the word and its `▶` reads the word
plus the example line from the enriched entry, so a card is one click away from
being heard.
## Speaking

The `▶` next to each pane, and the one next to the word in the review window,
speak the text. Windows' built-in SAPI voices (Huihui / Zira) sound robotic, so
speech goes through the Edge neural endpoint instead:

```
node pkg/tools/say.mjs --text-file <in.txt> <out.mp3> [voice]
```

`msedge-tts` is a normal dependency of this package (no API key needed); the
helper writes the text to a temp file, runs that script, and plays the mp3 with
WPF's `MediaPlayer`. Voices: `zh-CN-XiaoxiaoNeural` for Chinese,
`en-US-AriaNeural` for everything else. If node, the module, or the network is
missing, it falls back to SAPI and says nothing about it — a silent failure to
speak should never block the card.

In the review window the example sentence is only read **after** you reveal the
answer: hearing it early would give the meaning away.
### Why the terminal never sees ^C

When UIA cannot report a selection, the helper falls back to copying: it clears
the clipboard, sends Ctrl+C, and reads the result back. In a terminal Ctrl+C is
an interrupt, so that fallback painted `^C` into the user's shell — and since a
copy can never succeed there, every gesture retried it.

Two guards now apply before any clipboard poke:

1. `Test-KeyboardSurface` — true for console windows (`ConsoleWindowClass`,
   `CASCADIA_HOSTING_WINDOW_CLASS`, mintty), terminal processes (`WindowsTerminal`,
   `conhost`, `cmd`, `powershell`, `pwsh`, `bash`, `wsl`, `wt`), and for the
   `xterm-helper-textarea` that xterm.js focuses inside VS Code / VS Code forks.
   Selection capture simply gives up there rather than interrupting the shell.
2. A 3 second cooldown (`$script:clipBlockedUntil`) after a failed copy, so the
   gesture retries do not fire another Ctrl+C.

`-SurfaceTest` prints what the guard sees for the window in front:

```
{"proc":"Doubao","class":"Chrome_WidgetWin_1","console":false,"keyboard":false,...}
```
### Copying

The pill's `复制` puts the captured selection on the clipboard and closes the
pill — useful when the text lives in an app that copies awkwardly, and the only
way to get it out is to paste it somewhere else.

Inside a terminal the copy chord changes: `Ctrl+C` is an interrupt there, so the
helper sends `Ctrl+Insert` instead (a copy binding that never reaches the shell).
When the terminal hides its selection from UI Automation and that chord still
produces nothing, capture gives up and the 3 second cooldown keeps further
gestures from poking the shell.