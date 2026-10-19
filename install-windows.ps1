# ============================================================
#  Meeting Notes for Windows.  Run once in PowerShell:
#    irm https://raw.githubusercontent.com/gapletona/Meeting-Summarizer/main/install-windows.ps1 | iex
#  Then type  meeting  whenever a call starts.
#  NOTE: requires the free VB-CABLE virtual audio device (guided below).
# ============================================================
$ErrorActionPreference = "Stop"
Write-Host "Installing Meeting Notes for Windows..."

$Support = "$env:LOCALAPPDATA\MeetingNotes"
$Bin     = "$env:LOCALAPPDATA\MeetingNotes\bin"
New-Item -ItemType Directory -Force -Path $Support, $Bin, "$([Environment]::GetFolderPath('Desktop'))\Meeting Notes" | Out-Null

# 1) Dependencies via winget (built into Windows 10/11)
Write-Host ">>> Installing ffmpeg, Python, and Ollama via winget..."
winget install --silent --accept-source-agreements --accept-package-agreements -e --id Gyan.FFmpeg    2>$null
winget install --silent --accept-package-agreements -e --id Python.Python.3.12                          2>$null
winget install --silent --accept-package-agreements -e --id Ollama.Ollama                               2>$null

# 2) Python env + cross-platform deps
Write-Host ">>> Building the local AI environment..."
py -3 -m venv "$Support\venv"
& "$Support\venv\Scripts\python.exe" -m pip install --quiet --upgrade pip
& "$Support\venv\Scripts\pip.exe" install --quiet faster-whisper openai
# NVIDIA GPU: faster-whisper needs CUDA 12 cuBLAS + cuDNN 9, which the driver doesn't ship.
# Without them transcription silently falls back to the (much slower) CPU.
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
  Write-Host ">>> NVIDIA GPU found - installing CUDA libraries for GPU transcription (~1 GB)..."
  & "$Support\venv\Scripts\pip.exe" install --quiet nvidia-cublas-cu12 "nvidia-cudnn-cu12>=9,<10"
}

# 3) Pull the summary model (one-time)
Write-Host ">>> Downloading the summary model (one-time)..."
Start-Process -NoNewWindow ollama -ArgumentList "serve"; Start-Sleep 2
ollama pull qwen3:4b-instruct 2>$null; if ($LASTEXITCODE -ne 0) { ollama pull qwen2.5:7b 2>$null }

# 4) Write the engine
Write-Host ">>> Installing the note engine..."
$engine = @'
#!/usr/bin/env python3
"""notes_engine.py - cross-platform. Transcribes + summarizes an audio file locally,
writes Markdown into --out-dir, prints ONLY that path on stdout (progress -> stderr).

Transcription backend is chosen automatically:
  - macOS on Apple Silicon  -> mlx-whisper (Metal GPU)
  - Windows / Linux         -> faster-whisper (NVIDIA GPU if present, else CPU)
Summarization is identical everywhere: a local Ollama / OpenAI-compatible server.
Existing transcripts (--transcript) can be .txt/.md, .vtt (Teams/Zoom) or .docx (Teams)."""
import argparse, html, json, platform, re, shutil, subprocess, sys, tempfile, time, urllib.request, zipfile
from pathlib import Path


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def fmt(s):
    m, s = divmod(int(round(s)), 60); h, m = divmod(m, 60)
    return f"{h}h {m}m {s}s" if h else (f"{m}m {s}s" if m else f"{s}s")


def collapse_repeats(text, max_run=3):
    out, run = [], 0
    for w in text.split():
        if out and w.lower() == out[-1].lower():
            run += 1
            if run >= max_run:
                continue
        else:
            run = 0
        out.append(w)
    return " ".join(out)


def pick_backend(forced):
    if forced:
        return forced
    if sys.platform == "darwin" and platform.machine() == "arm64":
        return "mlx"
    return "faster"


def add_cuda_dll_dirs():
    """Windows: let CTranslate2 find the cuBLAS/cuDNN DLLs from the nvidia-* pip wheels."""
    if sys.platform != "win32":
        return
    import os, site
    for sp in site.getsitepackages():
        for bin_dir in Path(sp, "nvidia").glob("*/bin"):
            os.add_dll_directory(str(bin_dir))
            os.environ["PATH"] = str(bin_dir) + os.pathsep + os.environ.get("PATH", "")


def transcribe(audio_path, backend, model):
    """Returns (text, seconds, audio_duration_seconds)."""
    t0 = time.perf_counter()
    if backend == "mlx":
        import mlx_whisper
        repo = model or "mlx-community/whisper-large-v3-turbo"
        log(f"Transcribing on the Apple GPU ({repo})...")
        r = mlx_whisper.transcribe(str(audio_path), path_or_hf_repo=repo,
                                   condition_on_previous_text=False)
        text = r["text"].strip()
        segs = r.get("segments", [])
        dur = segs[-1]["end"] if segs else 0.0
    else:
        add_cuda_dll_dirs()
        from faster_whisper import WhisperModel
        try:
            import ctranslate2
            cuda = ctranslate2.get_cuda_device_count() > 0
        except Exception:
            cuda = False
        device = "cuda" if cuda else "cpu"
        compute = "float16" if cuda else "int8"
        name = model or "large-v3-turbo"
        log(f"Transcribing with faster-whisper ({name}, {device})...")

        def load(dev, comp):
            return WhisperModel(name, device=dev, compute_type=comp)

        try:
            wm = load(device, compute)
        except RuntimeError as e:
            if device == "cuda":
                log(f"GPU unavailable ({e}); falling back to CPU...")
                device, compute = "cpu", "int8"
                wm = load(device, compute)
            else:
                raise

        # Split into short chunks before handing anything to whisper. faster-whisper's
        # numpy feature extractor can blow up to tens of GB of RAM on long recordings
        # (a known issue on big files); capping each call to ~60s keeps memory bounded
        # no matter how long the meeting runs.
        chunk_dir = Path(tempfile.mkdtemp(prefix="mn_chunks_"))
        try:
            pattern = str(chunk_dir / "chunk_%04d.wav")
            subprocess.run(
                ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(audio_path),
                 "-f", "segment", "-segment_time", "60", "-c", "copy", pattern],
                check=True,
            )
            chunk_files = sorted(chunk_dir.glob("chunk_*.wav"))
            if not chunk_files:
                chunk_files = [audio_path]

            texts, dur = [], 0.0
            for i, chunk in enumerate(chunk_files):
                log(f"  chunk {i + 1}/{len(chunk_files)}...")
                try:
                    segments, info = wm.transcribe(str(chunk), condition_on_previous_text=False)
                    segments = list(segments)
                except RuntimeError as e:
                    if device == "cuda":
                        log(f"GPU transcription failed mid-run ({e}); switching to CPU...")
                        device, compute = "cpu", "int8"
                        wm = load(device, compute)
                        segments, info = wm.transcribe(str(chunk), condition_on_previous_text=False)
                        segments = list(segments)
                    else:
                        raise
                texts.append(" ".join(seg.text.strip() for seg in segments).strip())
                dur += getattr(info, "duration", 0.0) or 0.0
            text = " ".join(t for t in texts if t)
        finally:
            shutil.rmtree(chunk_dir, ignore_errors=True)
    return collapse_repeats(text), time.perf_counter() - t0, dur


SYSTEM_PROMPT = """You are an expert meeting-notes assistant. Given a raw, possibly messy meeting \
transcript, produce clean Markdown notes with exactly these sections:

## TL;DR
One or two sentences with the single most important outcome.

## Key Points
Main topics, as concise bullets.

## Decisions
Concrete decisions made. If none, write "None recorded."

## Action Items
A checklist. Each line: - [ ] <task> - <owner if mentioned, else 'unassigned'> (<due date if mentioned>)

## Open Questions
Anything left unresolved.

Be faithful to the transcript. Do NOT invent names, numbers, dates, or commitments. Keep it tight."""


PART_PROMPT = """You are an expert meeting-notes assistant. You are given ONE PART of a longer \
meeting transcript. Extract, as terse Markdown bullets under these headings, only what this part contains:

### Key Points
### Decisions
### Action Items
(each line: - [ ] <task> - <owner if mentioned, else 'unassigned'> (<due date if mentioned>))
### Open Questions

Keep speaker names exactly as written. Do NOT invent anything. Omit a heading if it has nothing."""


# ---------- transcript files (Teams .vtt / .docx, or plain text) ----------

def merge_turns(turns):
    """[(speaker, text)] -> 'Speaker: text' lines, joining consecutive turns by the same speaker."""
    merged = []
    for spk, text in turns:
        text = " ".join(text.split())
        if not text:
            continue
        if merged and spk and merged[-1][0] == spk:
            merged[-1][1] += " " + text
        else:
            merged.append([spk, text])
    return "\n".join(f"{s}: {t}" if s else t for s, t in merged)


def parse_vtt(raw):
    """WebVTT -> speaker turns. Drops the header, cue ids and timestamps; keeps <v Name> speakers."""
    turns = []
    for block in re.split(r"\n\s*\n", raw.replace("\r", "")):
        lines = block.strip().split("\n")
        ts = next((i for i, l in enumerate(lines) if "-->" in l), None)
        if ts is None:            # WEBVTT header, NOTE / STYLE blocks
            continue
        for line in lines[ts + 1:]:
            m = re.match(r"\s*<v\s+([^>]+)>(.*)", line)
            spk, text = (m.group(1).strip(), m.group(2)) if m else (None, line)
            text = html.unescape(re.sub(r"<[^>]+>", "", text)).strip()
            if spk is None:
                if turns and not re.match(r"^[^:]{1,40}:\s", text):
                    spk = turns[-1][0]                          # continuation of the same cue
                else:
                    m2 = re.match(r"^([^:]{1,40}):\s+(.*)", text)  # Zoom style "Name: text"
                    spk, text = (m2.group(1).strip(), m2.group(2)) if m2 else (None, text)
            turns.append((spk, text))
    return merge_turns(turns)


def parse_docx(path):
    """Teams .docx transcript -> speaker turns. Standard library only (no python-docx)."""
    with zipfile.ZipFile(path) as z:
        xml = z.read("word/document.xml").decode("utf-8", errors="replace")
    paras = []
    for p in re.findall(r"<w:p[ >].*?</w:p>", xml, flags=re.S):
        p = re.sub(r"<w:(tab|br)\b[^>]*/>", " ", p)
        text = "".join(re.findall(r"<w:t[^>]*>([^<]*)</w:t>", p))
        text = html.unescape(text).strip()
        if text:
            paras.append(text)
    # Teams writes a "Name   0:03" (or "Name 1:02:03") line before each turn.
    header = re.compile(r"^(.{1,60}?)\s+(?:\d{1,2}:)?\d{1,2}:\d{2}(?:\.\d+)?$")
    turns, spk = [], None
    for text in paras:
        m = header.match(text)
        if m:
            spk = m.group(1).strip()
        else:
            turns.append((spk, text))
    return merge_turns(turns)


def load_transcript(path):
    """Returns (clean transcript text, label for the notes header)."""
    ext = path.suffix.lower()
    if ext == ".docx":
        return parse_docx(path), "Word transcript"
    raw = path.read_text(encoding="utf-8-sig", errors="replace")
    if ext == ".vtt" or raw.lstrip().startswith("WEBVTT"):
        return parse_vtt(raw), "VTT transcript"
    return raw.strip(), "provided transcript"


# ---------- summarization ----------

def ollama_root(base_url):
    """If base_url is an Ollama server, return its root URL (for the native API), else None."""
    root = re.sub(r"/v1/?$", "", base_url.rstrip("/"))
    try:
        with urllib.request.urlopen(f"{root}/api/version", timeout=3) as r:
            return root if "version" in json.load(r) else None
    except Exception:
        return None


def make_chat(llm, base_url, api_key, ctx):
    """Returns chat(system, user) -> text. On Ollama it uses the native API so the context window
    can be set per request (its OpenAI endpoint is stuck at the server default, often 4096)."""
    root = ollama_root(base_url)
    if root:
        def chat(system, user):
            body = {"model": llm, "stream": False,
                    "options": {"num_ctx": ctx, "temperature": 0.2},
                    "messages": [{"role": "system", "content": system},
                                 {"role": "user", "content": user}]}
            req = urllib.request.Request(f"{root}/api/chat", json.dumps(body).encode(),
                                         {"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=1800) as r:
                return json.load(r)["message"]["content"]
    else:
        from openai import OpenAI
        client = OpenAI(base_url=base_url, api_key=api_key)

        def chat(system, user):
            resp = client.chat.completions.create(
                model=llm, temperature=0.2,
                messages=[{"role": "system", "content": system}, {"role": "user", "content": user}])
            return resp.choices[0].message.content
    # Reasoning models (e.g. qwen3:4b) may prefix their answer with a <think> block.
    return lambda system, user: re.sub(r"<think>.*?</think>", "", chat(system, user), flags=re.S).strip()


def split_text(text, max_chars):
    """Split on line (speaker-turn) boundaries into pieces of at most max_chars."""
    pieces, cur = [], ""
    for line in text.split("\n"):
        while len(line) > max_chars:                   # one enormous line: cut at a space
            cut = line.rfind(" ", 0, max_chars)
            cut = cut if cut > 0 else max_chars
            if cur:
                pieces.append(cur)
                cur = ""
            pieces.append(line[:cut])
            line = line[cut:].lstrip()
        if cur and len(cur) + len(line) + 1 > max_chars:
            pieces.append(cur)
            cur = line
        else:
            cur = f"{cur}\n{line}" if cur else line
    if cur.strip():
        pieces.append(cur)
    return pieces


def summarize(transcript, llm, base_url, api_key, ctx=16384):
    t0 = time.perf_counter()
    chat = make_chat(llm, base_url, api_key, ctx)
    # Room for the transcript = context minus prompt overhead and ~2k tokens of reply.
    # ~3.5 characters per token is a safe estimate for English.
    max_chars = max(4000, int((ctx - 3000) * 3.5))
    if len(transcript) <= max_chars:
        log("Summarizing with the local model...")
        notes = chat(SYSTEM_PROMPT, f"Here is the meeting transcript:\n\n{transcript}")
        return notes, time.perf_counter() - t0

    # Too long for one pass: notes per part, then (if needed, repeatedly) condense, then final notes.
    parts = split_text(transcript, max_chars)
    log(f"Long transcript - summarizing in {len(parts)} parts...")
    partials = []
    for i, part in enumerate(parts, 1):
        log(f"  part {i}/{len(parts)}...")
        partials.append(chat(PART_PROMPT, f"Transcript part {i} of {len(parts)}:\n\n{part}"))
    combined = "\n\n".join(f"## Part {i}\n{n}" for i, n in enumerate(partials, 1))
    for _ in range(3):                                 # bounded, in case notes don't shrink
        if len(combined) <= max_chars:
            break
        groups = split_text(combined, max_chars)
        log(f"  condensing {len(groups)} groups of part-notes...")
        combined = "\n\n".join(chat(PART_PROMPT, f"Notes from consecutive parts of one meeting:\n\n{g}")
                               for g in groups)
    log("  writing the final notes...")
    notes = chat(SYSTEM_PROMPT, "These are notes taken from consecutive parts of ONE meeting, in order. "
                                "Merge them into the final notes, removing duplicates. Where a later part "
                                "changes an earlier decision, keep only the later one. Use exactly the "
                                "sections and the '- [ ]' checklist format specified."
                                f"\n\n{combined}")
    return notes, time.perf_counter() - t0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("audio", nargs="?", default=None,
                   help="Audio file to transcribe (omit if using --transcript)")
    p.add_argument("--transcript", default=None,
                   help="Skip audio/whisper entirely and summarize this text/markdown file instead")
    p.add_argument("--out-dir", required=True)
    p.add_argument("--backend", choices=["mlx", "faster"], default=None,
                   help="Force a transcription backend (default: auto by OS)")
    p.add_argument("--model", default=None, help="Whisper model (default per backend)")
    p.add_argument("--llm", default="qwen3:4b")
    p.add_argument("--base-url", default="http://localhost:11434/v1")
    p.add_argument("--api-key", default="not-needed")
    p.add_argument("--ctx", type=int, default=16384,
                   help="LLM context window in tokens; longer transcripts are summarized in parts")
    args = p.parse_args()

    if args.transcript:
        tpath = Path(args.transcript).expanduser()
        if not tpath.exists():
            log(f"Transcript not found: {tpath}"); sys.exit(1)
        transcript, backend = load_transcript(tpath)
        if not transcript:
            transcript = "(Empty transcript file.)"
        t_tx = 0.0
        log(f"Loaded {backend}: {len(transcript.split()):,} words")
    elif args.audio:
        audio = Path(args.audio).expanduser()
        if not audio.exists():
            log(f"Audio not found: {audio}"); sys.exit(1)
        backend = pick_backend(args.backend)
        transcript, t_tx, dur = transcribe(audio, backend, args.model)
        if not transcript:
            transcript = "(No speech detected in the recording.)"
    else:
        log("Provide either an audio file or --transcript <file>"); sys.exit(1)

    notes, t_sum = summarize(transcript, args.llm, args.base_url, args.api_key, args.ctx)

    out_dir = Path(args.out_dir).expanduser(); out_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y-%m-%d_%H-%M")
    out_path = out_dir / f"Meeting Notes {stamp}.md"
    header = (f"# Meeting Notes - {stamp}\n\n"
              f"*Generated 100% locally ({backend}) - transcription {fmt(t_tx)} - summary {fmt(t_sum)}*\n\n")
    out_path.write_text(header + notes + "\n\n---\n\n## Full Transcript\n\n" + transcript + "\n",
                        encoding="utf-8")

    log(f"Done in {fmt(t_tx + t_sum)} - $0.00")
    print(str(out_path))


if __name__ == "__main__":
    main()
'@
Set-Content -Path "$Support\notes_engine.py" -Value $engine -Encoding UTF8

# 5) Discover audio devices and ask the user to confirm them
Write-Host ""
Write-Host ">>> Your audio input devices (look for 'CABLE Output' and your microphone):"
ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | Select-String "audio"
$SysDevice = Read-Host "`nPaste your SYSTEM-audio device name (usually: CABLE Output (VB-Audio Virtual Cable))"
if ([string]::IsNullOrWhiteSpace($SysDevice)) { $SysDevice = "CABLE Output (VB-Audio Virtual Cable)" }
$MicDevice = Read-Host "Paste your MICROPHONE device name (from the list above)"

# 6) Config
@"
# LLM provider (any OpenAI-compatible server). Edit to switch:
# Ollama :11434/v1 | LM Studio :1234/v1 | oMLX :8005/v1 | llama.cpp :8080/v1 | OpenAI https://api.openai.com/v1
`$Llm = "qwen3:4b-instruct"
`$BaseUrl = "http://localhost:11434/v1"
`$ApiKey = "not-needed"
# LLM context window in tokens. 16384 fits ~50 min of meeting in one pass on an 8 GB GPU;
# longer meetings are summarized in parts automatically.
`$Ctx = 16384
`$SysDevice = "$SysDevice"
`$MicDevice = "$MicDevice"
# Where notes are saved. Default: "Meeting Notes" on your Desktop (follows OneDrive Desktop redirection).
#`$OutDir = "D:\Notes\Meetings"
"@ | Set-Content -Path "$Support\config.ps1" -Encoding UTF8

# 7) Write the meeting command
$meeting = @'
# meeting.ps1 (Windows) - records system audio (via VB-CABLE) + mic, makes notes locally.
#   meeting -Transcript <file>  summarizes an existing transcript (.vtt / .docx / .txt) instead.
param([string]$Model, [string]$Provider, [string]$Url, [string]$Key, [switch]$List,
      [string]$Transcript, [int]$Context)
$Support = "$env:LOCALAPPDATA\MeetingNotes"
$OutDir  = "$([Environment]::GetFolderPath('Desktop'))\Meeting Notes"   # default; config.ps1 can override
. "$Support\config.ps1"   # sets $Llm, $BaseUrl, $ApiKey, $SysDevice, $MicDevice
if (-not $ApiKey) { $ApiKey = "not-needed" }
switch ($Provider) {
  "ollama"   { $BaseUrl = "http://localhost:11434/v1" }
  "lmstudio" { $BaseUrl = "http://localhost:1234/v1" }
  "omlx"     { $BaseUrl = "http://localhost:8005/v1" }
  "llamacpp" { $BaseUrl = "http://localhost:8080/v1" }
  "openai"   { $BaseUrl = "https://api.openai.com/v1" }
}
if ($Url)   { $BaseUrl = $Url }
if ($Key)   { $ApiKey = $Key }
if ($Model) { $Llm = $Model }
if ($Context) { $Ctx = $Context } elseif (-not $Ctx) { $Ctx = 16384 }   # $Ctx may come from config.ps1
if ($List) {
  & "$Support\venv\Scripts\python.exe" -c "from openai import OpenAI; [print(' -', m.id) for m in OpenAI(base_url='$BaseUrl', api_key='$ApiKey').models.list().data]"
  exit
}
Write-Host "Model: $Llm  @  $BaseUrl"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if ($Transcript) {
  if (-not (Test-Path -LiteralPath $Transcript)) { Write-Host "Transcript file not found: $Transcript"; exit 1 }
  $Transcript = (Resolve-Path -LiteralPath $Transcript).Path
  Write-Host "Summarizing transcript locally..."
  $NoteFile = & "$Support\venv\Scripts\python.exe" "$Support\notes_engine.py" --transcript "$Transcript" `
                --out-dir "$OutDir" --llm $Llm --base-url $BaseUrl --api-key $ApiKey --ctx $Ctx
  if (-not $NoteFile) { Write-Host "Could not generate notes - is Ollama running? Try: ollama serve"; exit 1 }
  Write-Host "Saved to: $NoteFile"
  Invoke-Item $OutDir
  exit
}

$Stamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$Audio = "$Support\rec_$Stamp.wav"

Write-Host "Recording - join your meeting now. Press  q  in this window to stop."
# input 1 = system audio captured via VB-CABLE; input 2 = your microphone; mixed to mono 16k
ffmpeg -hide_banner -loglevel error `
  -f dshow -i "audio=$SysDevice" `
  -f dshow -i "audio=$MicDevice" `
  -filter_complex "amix=inputs=2:duration=longest:normalize=0" -ac 1 -ar 16000 "$Audio"

Write-Host "Transcribing and summarizing locally..."
$NoteFile = & "$Support\venv\Scripts\python.exe" "$Support\notes_engine.py" "$Audio" `
              --out-dir "$OutDir" --backend faster --llm $Llm --base-url $BaseUrl --api-key $ApiKey --ctx $Ctx
if (-not $NoteFile) { Write-Host "Could not generate notes - is Ollama running? Try: ollama serve"; exit 1 }
Remove-Item $Audio -ErrorAction SilentlyContinue
Write-Host "Saved to: $OutDir"
Invoke-Item $OutDir
'@
Set-Content -Path "$Bin\meeting.ps1" -Value $meeting -Encoding UTF8

# 8) Create a `meeting` shim on PATH
@"
@echo off
powershell -ExecutionPolicy Bypass -File `"$Bin\meeting.ps1`" %*
"@ | Set-Content -Path "$Bin\meeting.cmd" -Encoding ASCII
$userPath = [Environment]::GetEnvironmentVariable("Path","User")
if ($userPath -notlike "*$Bin*") {
  [Environment]::SetEnvironmentVariable("Path", "$userPath;$Bin", "User")
}

Write-Host ""
Write-Host "============================================================"
Write-Host "  ALMOST DONE - one manual step (like Mac's BlackHole):"
Write-Host ""
Write-Host "  1) Install the FREE VB-CABLE driver:  https://vb-audio.com/Cable/"
Write-Host "     (download, run Setup as admin, then REBOOT)"
Write-Host "  2) Windows Sound settings -> set 'CABLE Input' as your"
Write-Host "     default OUTPUT during calls, and enable 'Listen to this"
Write-Host "     device' on 'CABLE Output' so you still hear the call."
Write-Host ""
Write-Host "  Then open a NEW terminal and run:   meeting   (press q to stop)"
Write-Host "  Notes land in:  Desktop\Meeting Notes"
Write-Host "============================================================"
