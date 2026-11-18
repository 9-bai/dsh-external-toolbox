/**
 * dsh-external-toolbox - host half.
 *
 * 1. Runs `helper/capture.ps1` as a long-lived child process. That helper owns a
 *    system-wide hotkey, grabs the selection in whatever application has focus,
 *    and shows its own floating card - so translating never needs the DSH
 *    window to be visible.
 * 2. Serves two exact same-origin GET routes for that helper and for the web
 *    half:
 *      /toolbox/translate?id=<id>&to=<lang>   -> JSON { ok, text } / { ok:false, error }
 *      /toolbox/latest                       -> JSON { seq, id, text, via, at, intent }
 */
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const name = "dsh-external-toolbox";

/**
 * Hard-depend on the HTTP server: the helper needs a real origin for its
 * translate URL, and registering before the listener exists would race. `llm`
 * is looked up lazily with ctx.get(), so a profile without a model still gets
 * the card and only the translate button reports "no model".
 */
export const inject = ["webServer"];

// Evaluated at import time: the one signal that proves the loader actually
// picked this package up (a plugin that never imports writes nothing).
try {
  appendFileSync(join(tmpdir(), "dsh-external-toolbox-host.log"), `${new Date().toISOString()} module evaluated\n`);
} catch {
  /* diagnostics must never break the import */
}

const LIB_DIR = dirname(fileURLToPath(import.meta.url));
const HELPER_PATH = join(LIB_DIR, "..", "helper", "capture.ps1");
const TRANSLATE_ROUTE = "/toolbox/translate";
const RUN_ROUTE = "/toolbox/run";
const LATEST_ROUTE = "/toolbox/latest";
const ACTIVATE_ROUTE = "/toolbox/activate";
const RESTART_DELAY_MS = 2000;
const LOG_PATH = join(tmpdir(), "dsh-external-toolbox-host.log");
const MAX_TEXT_CHARS = 20000;
const MAX_TRANSLATE_CHARS = 100000;
const TRANSLATE_TIMEOUT_MS = 90000;
const HISTORY = 8;
const VOCAB_ROUTE = "/toolbox/vocab";
const REVIEW_ROUTE = "/toolbox/review";
// %APPDATA% on Windows, ~/.config elsewhere: the vocabulary book has to outlive
// profile reinstalls, so it does not live next to the plugin.
const VOCAB_DIR = join(process.env.APPDATA ?? join(homedir(), ".config"), "dsh-external-toolbox");
const VOCAB_JSONL = join(VOCAB_DIR, "vocab.jsonl");
const VOCAB_MARKDOWN = join(VOCAB_DIR, "生词本.md");

// The desktop shell runs this plugin inside the Electron main process, so the
// real BrowserWindow API is reachable. Showing the window through it is the
// same code path the tray icon takes - the only one where Electron's visibility
// state and the native HWND agree.
const nodeRequire = createRequire(import.meta.url);
const electronApi = () => {
  try {
    return nodeRequire("electron");
  } catch {
    return null;
  }
};

/**
 * Bring the DSH window back the way the app itself does it.
 * @returns {{ ok: boolean, windows?: number, visible?: boolean, error?: string }}
 */
function showHostWindow() {
  const electron = electronApi();
  if (electron === null || electron === undefined || typeof electron.BrowserWindow?.getAllWindows !== "function") {
    return { ok: false, error: "electron api unavailable" };
  }
  try {
    const windows = electron.BrowserWindow.getAllWindows().filter((window) => window.isDestroyed() !== true);
    if (windows.length === 0) return { ok: false, error: "no window" };
    // Prefer the biggest window: devtools and helper windows must not win.
    const area = (window) => {
      try {
        const [width, height] = window.getSize();
        return width * height;
      } catch {
        return 0;
      }
    };
    const target = windows.reduce((best, window) => (area(window) > area(best) ? window : best), windows[0]);
    if (target.isMinimized()) target.restore();
    target.show();
    target.focus();
    try {
      electron.app?.focus?.({ steal: true });
    } catch {
      /* app.focus is best effort */
    }
    // A window that was hidden or occluded can come back showing its last
    // frame: Windows throttles compositing for windows it considers occluded,
    // and re-showing does not always clear that. Ask for a repaint, then nudge
    // the size by a pixel and back so the compositor has to recompute.
    try {
      target.webContents?.invalidate?.();
    } catch {
      /* invalidate is optional */
    }
    try {
      const [width, height] = target.getContentSize();
      target.setContentSize(width + 1, height);
      target.setContentSize(width, height);
    } catch {
      /* the nudge is best effort */
    }
    return { ok: true, windows: windows.length, visible: target.isVisible() };
  } catch (error) {
    return { ok: false, error: describe(error) };
  }
}

const LANGUAGES = new Set(["zh", "en", "ja", "ko", "es", "fr", "de", "ru", "pt", "it"]);

const LANGUAGE_NAMES = {
  zh: "Simplified Chinese",
  en: "English",
  ja: "Japanese",
  ko: "Korean",
  es: "Spanish",
  fr: "French",
  de: "German",
  ru: "Russian",
  pt: "Portuguese",
  it: "Italian",
};

// Han, Hiragana/Katakana, and Hangul: text built mostly from these is not
// English, so the automatic direction goes the other way.
const CJK_RE = /[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uac00-\ud7af]/g;
const LATIN_RE = /[A-Za-z]/g;

/**
 * Bilingual default: Chinese (and Japanese/Korean) selections translate to
 * English, everything else translates to Chinese. Explicit `to=` still wins.
 */
export function detectTarget(text) {
  const cjk = (text.match(CJK_RE) ?? []).length;
  const latin = (text.match(LATIN_RE) ?? []).length;
  if (cjk === 0) return "zh";
  if (latin === 0) return "en";
  return cjk >= latin ? "en" : "zh";
}

export function apply(ctx, config) {
  const options = config ?? {};
  const hotkey = typeof options.hotkey === "string" && options.hotkey.trim() !== "" ? options.hotkey.trim() : "Ctrl+Alt+Q";
  const defaultTarget = options.target === "auto" || LANGUAGES.has(options.target) ? options.target : "auto";

  const log = (...args) => {
    const line = `${new Date().toISOString()} ${args.map((part) => (typeof part === "string" ? part : describe(part))).join(" ")}`;
    // The desktop app's stderr is not reachable from outside, so keep a file the
    // user (and support) can read after a restart.
    try {
      appendFileSync(LOG_PATH, `${line}\n`);
    } catch {
      /* logging must never take the plugin down */
    }
    try {
      console.error("[select-translate]", ...args);
    } catch {
      /* logging must never take the plugin down */
    }
  };

  log(`apply (helper=${HELPER_PATH})`);

  /** id -> { text, at }, newest last; the helper translates by id. */
  const captures = new Map();
  let latest = { seq: 0, id: "", text: "", via: "", at: 0, intent: "" };
  let child = null;
  let stopped = false;
  let restartTimer = null;
  let leftover = "";

  /** Resolved on demand: the llm service may mount after this plugin. */
  const takeLlm = () => {
    try {
      return ctx.get("llm");
    } catch (error) {
      log("llm service unavailable:", describe(error));
      return undefined;
    }
  };

  const remember = (text, via, id) => {
    captures.set(id, { text, at: Date.now() });
    while (captures.size > HISTORY) {
      const oldest = captures.keys().next();
      if (oldest.done) break;
      captures.delete(oldest.value);
    }
    latest = { seq: latest.seq + 1, id, text, via, at: Date.now(), intent: "" };
  };

  const resolveRoute = () => {
    try {
      const selection = ctx.get("agentDefaultModel")?.currentSelection?.();
      if (selection?.provider !== undefined && selection.model !== undefined) {
        return { provider: selection.provider, model: selection.model };
      }
    } catch (error) {
      log("default model lookup failed:", describe(error));
    }
    return undefined;
  };

  const prepareCall = async (llm, route, signal, limits) => {
    const prepared = { provider: route.provider, model: route.model, reasoningEffort: "off" };
    if (limits !== undefined) Object.assign(prepared, limits);
    try {
      return await llm.prepareCall(prepared, signal);
    } catch (error) {
      signal.throwIfAborted();
      log(`call config rejected (${route.provider}/${route.model}): ${describe(error)}`);
      return llm.prepareCall(route, signal);
    }
  };

  const runTask = async (text, task, target) => {
    const route = resolveRoute();
    if (route === undefined) throw new Error("没有可用的默认模型，请先在 DSH 里选好模型");
    const llmService = takeLlm();
    if (llmService === undefined) throw new Error("模型服务不可用");
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(new Error("翻译超时")), TRANSLATE_TIMEOUT_MS);
    try {
      const call = await prepareCall(llmService, route, controller.signal, { maxTokens: 8192 });
      const language = LANGUAGE_NAMES[target] ?? LANGUAGE_NAMES.zh;
      const system =
        task === "explain"
          ? `You explain things for a working developer. Explain the user's text in ${language}: what it is, what it does, and anything worth knowing (syntax, intent, pitfalls). Match the input: source code gets a code-level walkthrough, an error message gets cause and fix, a term gets a two-sentence definition. Keep it short and concrete, no preamble, no restating the input.`
          : `You are a translation engine. Translate the user's text into ${language}. Preserve the original formatting and paragraph breaks. Output only the translation, with no preamble, notes or quotation marks.`;
      const messages = [
        {
          id: randomUUID(),
          role: "user",
          content: [{ type: "text", text }],
          source: { kind: "dsh-external-toolbox" },
        },
      ];
      let accumulated = "";
      let failure;
      for await (const chunk of call.stream({
        ...call.config,
        messages,
        system,
        purpose: "select-translate",
        signal: controller.signal,
      })) {
        if (chunk.type === "text-delta") accumulated += chunk.text ?? "";
        else if (chunk.type === "block-end" && chunk.block?.type === "text" && accumulated === "") accumulated = chunk.block.text ?? "";
        else if (chunk.type === "finish") { failure = chunk.reason; if (chunk.reason?.kind === "max-tokens") log("output hit max-tokens"); }
      }
      controller.signal.throwIfAborted();
      if (failure?.kind === "error" || failure?.kind === "aborted") {
        const detail = failure.failure?.message ?? "翻译失败";
        throw new Error(failure.failure?.code === undefined ? detail : `${failure.failure.code}: ${detail}`);
      }
      const translated = accumulated.trim();
      if (translated === "") throw new Error("模型没有返回译文");
      return translated;
    } finally {
      clearTimeout(timer);
    }
  };

  /**
   * A dictionary entry for one saved word. Runs after the word is already on
   * disk, so a slow or missing model never blocks the card.
   */
  const describeWord = async (word, sentence) => {
    const route = resolveRoute();
    if (route === undefined) return "";
    const llmService = takeLlm();
    if (llmService === undefined) return "";
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(new Error("lookup timeout")), TRANSLATE_TIMEOUT_MS);
    try {
      const call = await prepareCall(llmService, route, controller.signal);
      const system = [
        "You are a compact learner's dictionary for a Chinese-speaking developer.",
        "For the given word or phrase, answer in Chinese except for the word itself.",
        "Output exactly these lines, skipping a line only when it does not apply:",
        "词性: <part of speech>",
        "释义: <one or two short Chinese senses, separated by ;>",
        "例句: <one short English example sentence>",
        "译文: <its Chinese translation>",
        "搭配: <two or three short collocations or 词根/词缀 notes>",
        "No preamble, no bullet symbols, no blank lines, no markdown.",
      ].join("\n");
      const messages = [
        {
          id: randomUUID(),
          role: "user",
          content: [{ type: "text", text: sentence.trim() === "" ? word : `${word}\n（出现在这句话里：${sentence}）` }],
          source: { kind: "dsh-external-toolbox" },
        },
      ];
      let accumulated = "";
      for await (const chunk of call.stream({
        ...call.config,
        messages,
        system,
        purpose: "select-translate",
        signal: controller.signal,
      })) {
        if (chunk.type === "text-delta") accumulated += chunk.text ?? "";
        else if (chunk.type === "block-end" && chunk.block?.type === "text" && accumulated === "") accumulated = chunk.block.text ?? "";
      }
      return accumulated.trim();
    } catch (error) {
      log("describe failed:", describe(error));
      return "";
    } finally {
      clearTimeout(timer);
    }
  };
  const json = (payload, status = 200) =>
    new Response(JSON.stringify(payload), {
      status,
      headers: {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "no-store",
        "access-control-allow-origin": "*",
      },
    });

  /**
   * One handler for every text task. `translate` keeps working for older
   * helpers; `run` takes a `task` parameter so new actions do not need a route.
   */
  const taskResource = async (request, forcedTask) => {
    let url;
    try {
      url = new URL(request.url);
    } catch {
      return json({ ok: false, error: "bad request" }, 400);
    }
    const task = forcedTask ?? (url.searchParams.get("task") ?? "translate");
    if (task !== "translate" && task !== "explain") return json({ ok: false, error: "unsupported task" }, 400);
    const requested = url.searchParams.get("to") ?? defaultTarget;
    if (requested !== "auto" && !LANGUAGES.has(requested)) return json({ ok: false, error: "unsupported target" }, 400);
    const id = url.searchParams.get("id");
    let text = "";
    if (id !== null && captures.has(id)) text = captures.get(id).text;
    else text = url.searchParams.get("q") ?? "";
    if (text.trim() === "") return json({ ok: false, error: "没有可处理的文本" }, 400);
    if (text.length > MAX_TRANSLATE_CHARS) {
      log(`input truncated ${String(text.length)} -> ${String(MAX_TRANSLATE_CHARS)}`);
      text = text.slice(0, MAX_TRANSLATE_CHARS);
    }
    // Translation aims at the opposite language; an explanation is for the
    // reader, so "auto" means "explain in Chinese" there.
    const target = requested !== "auto" ? requested : task === "explain" ? "zh" : detectTarget(text);
    try {
      const output = await runTask(text, task, target);
      return json({ ok: true, task, target, auto: requested === "auto", text: output });
    } catch (error) {
      log(`${task} failed:`, describe(error));
      return json({ ok: false, error: describe(error) }, 200);
    }
  };

  const translateResource = (request) => taskResource(request, "translate");
  const runResource = (request) => taskResource(request, undefined);

  // At most once: once a consumer reads the ask intent, clear it so a stale
  // intent cannot be re-applied by a component that re-mounted.
  let pollCount = 0;
  const latestResource = () => {
    // The browser half polls every 800ms. A gap in these counts means the
    // renderer stopped running, which is not the same as the window hanging.
    pollCount += 1;
    if (pollCount % 25 === 0) log(`client poll ${String(pollCount)}`);
    return json(latest);
  };

  /**
   * Vocabulary book: one JSON line per saved pair, plus a Markdown mirror so
   * the file can be opened (and reviewed) without any tooling.
   */
  const readVocab = () => {
    try {
      const raw = readFileSync(VOCAB_JSONL, "utf8");
      const latest = new Map();
      for (const line of raw.split("\n")) {
        const trimmed = line.trim();
        if (trimmed === "") continue;
        let entry;
        try {
          entry = JSON.parse(trimmed);
        } catch {
          continue;
        }
        if (entry === null || typeof entry !== "object") continue;
        if (typeof entry.word !== "string" || entry.word.trim() === "") continue;
        // The log is append-only: a later line for the same word replaces it.
        latest.set(entry.word.trim().toLowerCase(), entry);
      }
      return [...latest.values()].map((entry) => ({
        ...entry,
        due: Number(entry.due ?? entry.at ?? Date.now()),
        interval: Number(entry.interval ?? 0),
        ease: Number(entry.ease ?? 2.5),
        reps: Number(entry.reps ?? 0),
      }));
    } catch {
      return [];
    }
  };

  // Spaced repetition, three grades. `again` puts the word back in ten minutes,
  // `hard` tomorrow, `good` multiplies the current interval.
  const enriching = new Set();
  const DAY_MS = 24 * 60 * 60 * 1000;
  const TEN_MIN_MS = 10 * 60 * 1000;
  const MAX_INTERVAL_DAYS = 120;

  const scheduleAfter = (entry, grade) => {
    const ease = Math.max(1.3, Number(entry.ease ?? 2.5));
    const interval = Math.max(0, Number(entry.interval ?? 0));
    const reps = Math.max(0, Number(entry.reps ?? 0));
    const next = { ...entry, reviewedAt: Date.now(), reps, ease, interval };
    if (grade === "again") {
      next.reps = 0;
      next.ease = Math.max(1.3, ease - 0.2);
      next.interval = 0;
      next.due = Date.now() + TEN_MIN_MS;
    } else if (grade === "hard") {
      next.reps = reps;
      next.ease = Math.max(1.3, ease - 0.15);
      next.interval = 1;
      next.due = Date.now() + DAY_MS;
    } else {
      next.reps = reps + 1;
      next.interval =
        next.reps === 1 ? 1 : next.reps === 2 ? 3 : Math.min(MAX_INTERVAL_DAYS, Math.max(1, interval) * ease);
      next.due = Date.now() + next.interval * DAY_MS;
    }
    next.at = entry.at;
    return next;
  };

  /** Markdown mirror: readable straight from notepad, newest word first. */
  const writeBook = () => {
    try {
      const rows = readVocab().sort((a, b) => Number(b.at ?? 0) - Number(a.at ?? 0));
      const lines = ["# 生词本", "", `共 ${rows.length} 条 · 更新于 ${new Date().toLocaleString()}`, ""];
      for (const row of rows) {
        const when = new Date(Number(row.at ?? Date.now())).toLocaleDateString();
        const meaning = String(row.translation ?? "").replace(/\s+/g, " ").trim();
        lines.push(`## ${row.word}`);
        lines.push("");
        if (meaning !== "") lines.push(`- 释义：${meaning}`);
        const detail = String(row.detail ?? "").trim();
        if (detail !== "") {
          for (const line of detail.split("\n")) {
            if (line.trim() !== "") lines.push(`- ${line.trim()}`);
          }
        }
        const state = `下次复习 ${Number(row.due ?? 0) <= Date.now() ? "现在" : new Date(Number(row.due)).toLocaleDateString()}`;
        lines.push(`- 收藏于 ${when} · ${state}`);
        lines.push("");
      }
      writeFileSync(VOCAB_MARKDOWN, `${lines.join("\n")}\n`);
    } catch (error) {
      log("vocab markdown failed:", describe(error));
    }
  };
  const saveVocab = (raw) => {
    const existing = readVocab().find(
      (item) => item.word.trim().toLowerCase() === String(raw.word).trim().toLowerCase(),
    );
    const entry = {
      ...raw,
      due: existing?.due ?? Date.now(),
      interval: existing?.interval ?? 0,
      ease: existing?.ease ?? 2.5,
      reps: existing?.reps ?? 0,
    };
    try {
      mkdirSync(VOCAB_DIR, { recursive: true });
    } catch (error) {
      log("vocab dir failed:", describe(error));
      return false;
    }
    // Same word twice within a minute is a double click, not two new words.
    const previous = readVocab().slice(-20);
    const duplicate = previous.find(
      (item) =>
        typeof item.word === "string" &&
        item.word.trim().toLowerCase() === entry.word.trim().toLowerCase() &&
        Date.now() - Number(item.at ?? 0) < 60_000,
    );
    if (duplicate !== undefined) return true;
    try {
      appendFileSync(VOCAB_JSONL, `${JSON.stringify(entry)}\n`);
    } catch (error) {
      log("vocab append failed:", describe(error));
      return false;
    }
    writeBook();
    return true;
  };

  /**
   * Review endpoint: `GET /toolbox/review` returns the next due word,
   * `GET /toolbox/review?word=<w>&grade=again|hard|good` records an answer and
   * returns the following card.
   */
  const reviewResource = (request) => {
    let url;
    try {
      url = new URL(request.url);
    } catch {
      return json({ ok: false, error: "bad request" }, 400);
    }
    const word = (url.searchParams.get("word") ?? "").trim();
    const grade = (url.searchParams.get("grade") ?? "").trim();
    if (word !== "" && (grade === "again" || grade === "hard" || grade === "good")) {
      const entries = readVocab();
      const current = entries.find((item) => item.word.trim().toLowerCase() === word.toLowerCase());
      if (current !== undefined) {
        const next = scheduleAfter(current, grade);
        try {
          appendFileSync(VOCAB_JSONL, `${JSON.stringify(next)}\n`);
        } catch (error) {
          log("review append failed:", describe(error));
          return json({ ok: false, error: "cannot write vocabulary file" }, 500);
        }
      }
    }
    const entries = readVocab();
    const now = Date.now();
    const due = entries
      .filter((item) => Number(item.due ?? 0) <= now)
      .sort((a, b) => Number(a.due ?? 0) - Number(b.due ?? 0));
    const upcoming = entries
      .filter((item) => Number(item.due ?? 0) > now)
      .sort((a, b) => Number(a.due ?? 0) - Number(b.due ?? 0));
    const next = due[0] ?? upcoming[0];
    if (next !== undefined && String(next.detail ?? "").trim() === "" && !enriching.has(next.word)) {
      // Backfill entries saved before the dictionary lookup existed (or while no
      // model was selected): the next look at the word fills it in.
      enriching.add(next.word);
      void describeWord(next.word, String(next.context ?? "")).then((detail) => {
        enriching.delete(next.word);
        if (detail === "") return;
        const current = readVocab().find((item) => item.word.trim().toLowerCase() === next.word.trim().toLowerCase());
        if (current === undefined) return;
        try {
          appendFileSync(VOCAB_JSONL, `${JSON.stringify({ ...current, detail, enrichedAt: Date.now() })}\n`);
          writeBook();
          log(`vocab backfilled: ${String(next.word).slice(0, 60)}`);
        } catch (error) {
          log("vocab backfill failed:", describe(error));
        }
      });
    }
    return json({
      ok: true,
      total: entries.length,
      due: due.length,
      nextDue: upcoming[0]?.due ?? 0,
      // The card only needs the word and its meaning; the schedule stays home.
      item:
        next === undefined
          ? null
          : {
              word: next.word,
              translation: next.translation ?? "",
              context: next.context ?? "",
              detail: next.detail ?? "",
              lang: next.lang ?? "",
            },
    });
  };
  const vocabResource = (request) => {
    // GET /toolbox/vocab?word=...&translation=... saves; plain GET lists.
    try {
      const url = new URL(request.url);
      const word = url.searchParams.get("word");
      if (word !== null && word.trim() !== "") {
        const saved = saveVocab({
          word: word.trim().slice(0, 200),
          translation: (url.searchParams.get("translation") ?? "").slice(0, 2000),
          lang: url.searchParams.get("lang") ?? "",
          task: url.searchParams.get("task") ?? "",
          at: Date.now(),
        });
        return json({ ok: saved, count: readVocab().length }, saved ? 200 : 500);
      }
    } catch (error) {
      log("vocab request failed:", describe(error));
    }
    const entries = readVocab();
    return json({ ok: true, count: entries.length, file: VOCAB_MARKDOWN, entries });
  };
  // The browser half reports lifecycle events here: an unbounded number of
  // "mount" lines would mean the overlay seat is re-mounting the bridge. An
  // "ask" beat doubles as the acknowledgement, so the intent is cleared only
  // after the composer actually received the draft.
  const BEAT_ROUTE = "/toolbox/beat";
  const beatResource = (request) => {
    try {
      const url = new URL(request.url);
      const kind = url.searchParams.get("kind") ?? "?";
      if (kind === "ask") latest = { ...latest, intent: "" };
      log(`client ${kind} ${url.searchParams.get("id") ?? ""}`);
    } catch {
      /* diagnostics only */
    }
    return json({ ok: true });
  };

  // Activation goes through Electron, not Win32: the helper asks here instead
  // of forcing a hidden HWND visible, which used to leave a frozen, unrepainted
  // window behind.
  const activateResource = () => {
    const result = showHostWindow();
    log(`activate ${result.ok ? "ok" : "failed"} ${result.error ?? ""}`.trim());
    return json(result, result.ok === true ? 200 : 503);
  };

  const handleLine = (raw) => {
    const line = raw.trim();
    if (line === "") return;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      log("helper printed a non-JSON line:", line.slice(0, 200));
      return;
    }
    if (message === null || typeof message !== "object") return;
    if (message.type === "ready") {
      log(`hotkey ready: ${String(message.hotkey)}`);
      return;
    }
    if (message.type === "error") {
      log(`helper error: ${String(message.message)}`);
      return;
    }
    if (message.type === "vocab" && typeof message.word === "string" && message.word.trim() !== "") {
      const context = typeof message.context === "string" ? message.context.slice(0, 2000) : "";
      const saved = saveVocab({
        word: message.word.trim().slice(0, 200),
        translation: typeof message.translation === "string" ? message.translation.slice(0, 2000) : "",
        context,
        lang: typeof message.lang === "string" ? message.lang : "",
        task: typeof message.task === "string" ? message.task : "",
        at: Date.now(),
      });
      log(`vocab ${saved ? "saved" : "failed"}: ${message.word.trim().slice(0, 60)}`);
      if (saved) {
        // Enrich in the background: the card already closed with a plain meaning,
        // and the review window picks up the fuller entry next time it opens.
        const word = String(message.word).trim();
        void describeWord(word, context).then((detail) => {
          if (detail === "") return;
          const existing = readVocab().find((item) => item.word.trim().toLowerCase() === word.toLowerCase());
          if (existing === undefined) return;
          try {
            appendFileSync(VOCAB_JSONL, `${JSON.stringify({ ...existing, detail, enrichedAt: Date.now() })}\n`);
            writeBook();
            log(`vocab enriched: ${word.slice(0, 60)}`);
          } catch (error) {
            log("vocab enrich append failed:", describe(error));
          }
        });
      }
      return;
    }
    if (message.type === "intent" && message.intent === "ask") {
      latest = { ...latest, intent: "ask", at: Date.now() };
      return;
    }
    if (message.type !== "selection" || typeof message.text !== "string") return;
    const text = message.text.length > MAX_TEXT_CHARS ? message.text.slice(0, MAX_TEXT_CHARS) : message.text;
    if (text.trim() === "") return;
    const id = typeof message.id === "string" && message.id !== "" ? message.id : randomUUID();
    remember(text, typeof message.via === "string" ? message.via : "", id);
  };

  const startHelper = (base) => {
    if (stopped) return;
    if (child !== null) return;
    if (!existsSync(HELPER_PATH)) {
      log("helper script missing:", HELPER_PATH);
      return;
    }
    try {
      child = spawn(
        "powershell.exe",
        [
          "-NoProfile",
          "-NonInteractive",
          "-ExecutionPolicy",
          "Bypass",
          "-STA",
          "-File",
          HELPER_PATH,
          "-Hotkey",
          hotkey,
          "-TranslateUrl",
          `${base}${TRANSLATE_ROUTE}`,
          "-ParentPid",
          String(process.pid),
        ],
        { windowsHide: true, stdio: ["ignore", "pipe", "pipe"] },
      );
    } catch (error) {
      log("helper spawn failed:", describe(error));
      return;
    }
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk) => {
      leftover += chunk;
      const lines = leftover.split(/\r?\n/);
      leftover = lines.pop() ?? "";
      for (const line of lines) handleLine(line);
    });
    log(`helper spawned pid=${String(child.pid)} base=${base}`);
    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (chunk) => {
      const text = String(chunk).trim();
      if (text !== "") log("helper stderr:", text.slice(0, 400));
    });
    child.on("error", (error) => log("helper process error:", describe(error)));
    child.on("exit", (code, signal) => {
      child = null;
      leftover = "";
      if (stopped) return;
      log(`helper exited (code=${String(code)} signal=${String(signal)}), restarting in ${RESTART_DELAY_MS}ms`);
      restartTimer = setTimeout(() => {
        restartTimer = null;
        startHelper(base);
      }, RESTART_DELAY_MS);
    });
  };

  const stopHelper = () => {
    stopped = true;
    if (restartTimer !== null) {
      clearTimeout(restartTimer);
      restartTimer = null;
    }
    try {
      child?.kill();
    } catch {
      /* already gone */
    }
    child = null;
  };

  const onDispose = (dispose) => {
    try {
      ctx.effect(() => dispose);
    } catch (error) {
      log("effect registration failed:", describe(error));
    }
  };

  const routeDisposers = [];

  const registerRoutes = (webServer) => {
    if (webServer === null || webServer === undefined || typeof webServer.register !== "function") return false;
    try {
      const registered = [
        webServer.register({ kind: "exact", path: TRANSLATE_ROUTE, resource: translateResource }),
      webServer.register({ kind: "exact", path: RUN_ROUTE, resource: runResource }),
      webServer.register({ kind: "exact", path: VOCAB_ROUTE, resource: vocabResource }),
      webServer.register({ kind: "exact", path: REVIEW_ROUTE, resource: reviewResource }),
        webServer.register({ kind: "exact", path: LATEST_ROUTE, resource: latestResource }),
        webServer.register({ kind: "exact", path: BEAT_ROUTE, resource: beatResource }),
        webServer.register({ kind: "exact", path: ACTIVATE_ROUTE, resource: activateResource }),
      ];
      for (const disposer of registered) {
        if (typeof disposer === "function") routeDisposers.push(disposer);
      }
      log("routes registered");
      return true;
    } catch (error) {
      log("route registration failed:", describe(error));
      return false;
    }
  };

  const helperBase = () => {
    try {
      const port = ctx.webServer?.port;
      if (typeof port === "number" && port > 0) return `http://127.0.0.1:${port}`;
    } catch {
      /* not bound yet */
    }
    return "";
  };

  // The helper needs a real origin in its command line, so wait until the
  // listener has a port: routes first, then the child process.
  let routesReady = false;
  let polling = false;
  let attempts = 0;
  const registerOnce = () => {
    if (routesReady) return true;
    routesReady = registerRoutes(ctx.webServer);
    return routesReady;
  };
  const poll = () => {
    if (stopped || child !== null) {
      polling = false;
      return;
    }
    const base = helperBase();
    if (registerOnce() && base !== "") {
      polling = false;
      startHelper(base);
      return;
    }
    attempts += 1;
    if (attempts > 240) {
      polling = false;
      log("giving up waiting for the web server port");
      return;
    }
    setTimeout(poll, 250);
  };
  polling = true;
  poll();

  onDispose(() => {
    stopHelper();
    for (const dispose of routeDisposers) {
      try {
        dispose();
      } catch {
        /* the server may already be gone */
      }
    }
  });
}

function describe(error) {
  if (error instanceof Error) {
    const code = error.code;
    return typeof code === "string" ? `${code}: ${error.message}` : error.message;
  }
}
