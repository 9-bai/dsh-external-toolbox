// Synthesize speech with Microsoft Edge's online voices.
//
//   node say.mjs --text-file <in.txt> <out.mp3> [voice]
//   node say.mjs <text> <out.mp3> [voice]
//
// The voice defaults to en-US-AriaNeural; Chinese text usually wants
// zh-CN-XiaoxiaoNeural. Kept dependency-light on purpose: the only dependency is
// `ws`, which ships no install scripts, because `dsh plugin add` treats ignored
// build scripts as a failed install.
import { randomUUID } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import WebSocket from "ws";
import { secMsGec } from "./sec-ms-gec.mjs";

const TRUSTED_CLIENT_TOKEN = "6A5AA1D4EAFF4E9FB37E23D68491D6F4";
const DEFAULT_VOICE = "en-US-AriaNeural";
const OUTPUT_FORMAT = "audio-24khz-48kbitrate-mono-mp3";
const GEC_VERSION = "2-143.0.3650.96";
const USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0";
const CONNECT_TIMEOUT_MS = 15000;
const TOTAL_TIMEOUT_MS = 45000;

function fail(message) {
  process.stderr.write(`say: ${message}\n`);
  process.exit(1);
}

function stamp() {
  return new Date().toISOString();
}

function escapeXml(text) {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function langOf(voice) {
  const parts = voice.split("-");
  return parts.length >= 2 ? `${parts[0]}-${parts[1]}` : "en-US";
}

/** A binary frame is: 2-byte header length (big endian), header text, audio. */
function audioOf(buffer) {
  if (buffer.length < 2) return Buffer.alloc(0);
  const headerLength = buffer.readUInt16BE(0);
  const start = 2 + headerLength;
  return start >= buffer.length ? Buffer.alloc(0) : buffer.subarray(start);
}

function buildConfig() {
  const config = {
    context: {
      synthesis: {
        audio: {
          metadataoptions: { sentenceBoundaryEnabled: "false", wordBoundaryEnabled: "false" },
          outputFormat: OUTPUT_FORMAT,
        },
      },
    },
  };
  return (
    `X-Timestamp:${stamp()}\r\n` +
    "Content-Type:application/json; charset=utf-8\r\n" +
    "Path:speech.config\r\n\r\n" +
    JSON.stringify(config)
  );
}

function buildSsml(text, voice) {
  const body =
    "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='" +
    langOf(voice) +
    "'>" +
    `<voice name='${voice}'>` +
    "<prosody rate='0%' pitch='+0Hz'>" +
    escapeXml(text) +
    "</prosody></voice></speak>";
  return (
    `X-RequestId:${randomUUID().replace(/-/g, "")}\r\n` +
    "Content-Type:application/ssml+xml\r\n" +
    `X-Timestamp:${stamp()}\r\n` +
    "Path:ssml\r\n\r\n" +
    body
  );
}

async function synthesize(text, voice) {
  const connectionId = randomUUID().replace(/-/g, "").toUpperCase();
  const gec = await secMsGec(TRUSTED_CLIENT_TOKEN);
  const url =
    "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1" +
    `?TrustedClientToken=${TRUSTED_CLIENT_TOKEN}&Sec-MS-GEC=${gec}` +
    `&Sec-MS-GEC-Version=${GEC_VERSION}&ConnectionId=${connectionId}`;

  const audio = [];
  const socket = new WebSocket(url, {
    headers: {
      Pragma: "no-cache",
      "Cache-Control": "no-cache",
      "User-Agent": USER_AGENT,
      Origin: "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
    },
  });

  return await new Promise((resolve, reject) => {
    let settled = false;
    const settle = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(connectTimer);
      clearTimeout(totalTimer);
      try {
        socket.terminate();
      } catch {}
      if (error) reject(error);
      else resolve(Buffer.concat(audio));
    };
    const connectTimer = setTimeout(() => settle(new Error("could not reach the voice service")), CONNECT_TIMEOUT_MS);
    const totalTimer = setTimeout(() => settle(new Error("timed out waiting for the voice service")), TOTAL_TIMEOUT_MS);

    socket.on("open", () => {
      clearTimeout(connectTimer);
      socket.send(buildConfig());
      socket.send(buildSsml(text, voice));
    });

    socket.on("message", (data, isBinary) => {
      if (!isBinary) {
        if (String(data).includes("Path:turn.end")) settle(null);
        return;
      }
      const chunk = audioOf(Buffer.from(data));
      if (chunk.length > 0) audio.push(chunk);
    });

    socket.on("unexpected-response", (_request, response) => {
      settle(new Error(`voice service refused the request (HTTP ${response.statusCode})`));
    });
    socket.on("error", () => settle(new Error("voice service connection failed")));
    socket.on("close", () => settle(audio.length > 0 ? null : new Error("voice service closed without audio")));
  });
}

const args = process.argv.slice(2);
let text;
let out;
let voice = DEFAULT_VOICE;

if (args[0] === "--text-file") {
  if (args.length < 3) fail("usage: say.mjs --text-file <in.txt> <out.mp3> [voice]");
  text = readFileSync(args[1], "utf8");
  out = args[2];
  if (args[3] !== undefined) voice = args[3];
} else {
  if (args.length < 2) fail("usage: say.mjs <text> <out.mp3> [voice]");
  text = args[0];
  out = args[1];
  if (args[2] !== undefined) voice = args[2];
}

text = String(text ?? "").trim();
if (text === "") fail("nothing to say");
if (text.length > 4000) text = text.slice(0, 4000);

const bytes = await synthesize(text, voice);
if (bytes.length === 0) fail("the voice service returned no audio");
writeFileSync(out, bytes);
process.stdout.write(JSON.stringify({ ok: true, bytes: bytes.length, voice }) + "\n");
