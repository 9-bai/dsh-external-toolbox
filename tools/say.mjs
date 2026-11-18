// say.mjs — synthesize one sentence to an mp3 file with the Edge neural voices.
//
//   node pkg/tools/say.mjs --text-file <in.txt> <out.mp3> [voice]
//   node pkg/tools/say.mjs "<text>" <out.mp3> [voice]
//
// Windows only ships the old SAPI voices (Huihui / Zira), which sound robotic;
// the Edge endpoint serves the neural ones (Xiaoxiao, Aria, ...) with no API key.
// The helper plays the resulting file and falls back to SAPI when this fails.
// Text is normally passed as a file: selection can contain quotes and newlines,
// which do not survive a command line.
import { MsEdgeTTS, OUTPUT_FORMAT } from "msedge-tts";
import { readFileSync, writeFileSync } from "node:fs";

const argv = process.argv.slice(2);
let text = "";
let rest = [];
if (argv[0] === "--text-file") {
  text = readFileSync(argv[1], "utf8");
  rest = argv.slice(2);
} else {
  text = argv[0] ?? "";
  rest = argv.slice(1);
}

const [outPath, voice = "en-US-AriaNeural"] = rest;

if (!text.trim() || !outPath) {
  console.error("usage: say.mjs (--text-file <in.txt> | <text>) <out.mp3> [voice]");
  process.exit(2);
}

const tts = new MsEdgeTTS();
await tts.setMetadata(voice, OUTPUT_FORMAT.AUDIO_24KHZ_48KBITRATE_MONO_MP3);

// toStream hands back a node Readable, so collect it instead of iterating.
const { audioStream } = tts.toStream(text);
const chunks = [];
audioStream.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
await new Promise((resolve, reject) => {
  audioStream.on("end", resolve);
  audioStream.on("error", reject);
});

const audio = Buffer.concat(chunks);
if (audio.length === 0) {
  console.error("no audio returned");
  process.exit(1);
}

writeFileSync(outPath, audio);
console.log(JSON.stringify({ ok: true, bytes: audio.length, voice }));
process.exit(0);
