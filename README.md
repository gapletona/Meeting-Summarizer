# Meeting Notes — Free, Forever, Local, and Private

Turn any meeting into clean, actionable notes in seconds. **100% on your Mac.** No subscriptions. No bots. No privacy trade-offs. Just one word: `meeting`.

---

## Why This Exists

I cancelled my Otter subscription. The notes were good, but the price wasn't the issue — the *principle* was. Every call I had was being shipped to their servers to transcribe. For conversations about comp, reviews, health decisions, or deals, that felt wrong. So I built a tool that runs the whole pipeline locally: record, transcribe, summarize — all on my own hardware.

The result: **clean notes in about a minute, no monthly bill, and zero bytes of audio ever leaving my laptop.**

---

## What You Get

Drop into a meeting, run one command, and when it ends you get a Markdown file like this:

```markdown
## TL;DR
Launch moved to Tuesday; the billing fix must land Friday.

## Decisions
- Delay the launch to next Tuesday to clear the billing bug first.

## Action Items
- [ ] Ship the billing fix — Priya (Friday)
- [ ] Draft the press release — unassigned

## Open Questions
- Who owns the press release?
```

Notes appear in **Desktop ▸ Meeting Notes** and are emailed to you automatically.

---

## Speed: The Numbers

On a MacBook Pro M5 Max:

- **Transcription**: A 9-minute meeting → text in **7 seconds** (78× faster than real time, via GPU)
- **Summarization**: Clean notes in **3–5 seconds** depending on your model choice
- **One-time setup**: ~2–3 minutes and 2 GB download

For a full one-hour meeting, you're looking at transcription in under 60 seconds, then another few seconds for notes. By the time you close your laptop, you're done.

---

## Install It — One Line

### macOS

```bash
curl -fsSL https://raw.githubusercontent.com/gapletona/Meeting-Summarizer/main/install.sh | bash
```

### Windows

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
irm https://raw.githubusercontent.com/gapletona/Meeting-Summarizer/main/install-windows.ps1 | iex
```

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/gapletona/Meeting-Summarizer/main/install-linux.sh | bash
```

#### What the installer does:

1. Checks for Homebrew (macOS/Linux) or Poetry (Windows) — prompts to install if missing
2. Installs `ffmpeg`, audio routing tools, and **Ollama** (the local AI runtime)
3. Sets up a Python virtual environment with `mlx-whisper` and the OpenAI client
4. Downloads the speech model (~800 MB) and default LLM (~2 GB)
5. Creates folders for notes and a support directory
6. Asks for your email (for automatic note delivery)
7. Walks you through a two-click audio setup (macOS asks for microphone permission)

**The first run takes a few minutes.** After that, everything is cached locally.

---

## Run It — One Word

```bash
meeting
```

That's it. Recording starts. Talk normally. When the call ends, press **q**. 

A minute later, your notes are ready in `Desktop/Meeting Notes` and in your inbox.

---

## Customize Your Setup

### Use a different AI model for a single call:

```bash
meeting qwen3:4b-instruct
```

### Switch AI providers:

```bash
meeting -p lmstudio          # Use LM Studio instead of Ollama
meeting -u http://localhost:8000/v1  # Point at any OpenAI-compatible endpoint
```

### List available models:

```bash
meeting --list
```

### View help:

```bash
meeting --help
```

---

## How It Works (No Magic, Just Code)

The entire pipeline is three steps:

### Step 1: Capture Your Audio

A single `ffmpeg` line captures everything your Mac hears — both the call and your voice — into a compressed 16 kHz mono file:

```bash
ffmpeg -f avfoundation -i ":Meeting Capture" -ac 1 -ar 16000 meeting.m4a
```

Nothing is sent anywhere. It's just written to your disk.

### Step 2: Transcribe (On Your GPU)

**Whisper** runs directly on your Apple Silicon GPU via MLX. A 9-minute call becomes text in ~7 seconds:

```python
import mlx_whisper

result = mlx_whisper.transcribe(
    "meeting.m4a",
    path_or_hf_repo="mlx-community/whisper-large-v3-turbo",
    condition_on_previous_text=False,  # prevents Whisper from looping on silence
)
transcript = result["text"]
```

### Step 3: Summarize (With a Local LLM)

The same OpenAI client everyone uses for ChatGPT — just pointed at `localhost`:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:11434/v1", api_key="not-needed")

resp = client.chat.completions.create(
    model="qwen3:4b-instruct",
    messages=[
        {"role": "system", "content": "Summarize into TL;DR, Decisions, Action Items. Don't invent."},
        {"role": "user", "content": transcript},
    ],
)
notes = resp.choices[0].message.content
```

The model runs on your machine. No internet. No API key. No bill.

### Step 4: Save and Email

Notes are written to Markdown, and a few lines of AppleScript send them to your Mail app.

---

## Comparison: Why This Is Different

| Feature | Meeting Notes | Otter (free) | Granola | Fathom (free) |
|---------|---|---|---|---|
| **Monthly cost** | $0 | $0 (capped) | ~$18 | $0 (capped) |
| **Minutes / month** | Unlimited | ~300 | Unlimited (paid) | Unlimited record |
| **AI summaries** | Unlimited | Limited | Unlimited (paid) | ~5/month |
| **Bot joins call** | Never | Yes | No | Yes |
| **Audio leaves device** | **Never** | Yes | Yes | Yes |
| **Works offline** | **Yes** | No | No | No |

---

## Privacy & Ownership

Your audio never leaves your Mac. Period.

- No vendor has it
- No cloud backup
- No terms of service to trust
- No monthly bill

This isn't about the $18. It's that your most sensitive conversations — comp, reviews, legal, health, deals — get the same effortless AI treatment as everything else, without you having to decide whether to trust a vendor with them.

---

## Troubleshooting

### "Command not found: meeting"

The installer adds a command to your shell. Restart Terminal or run:

```bash
source ~/.zshrc      # if using zsh
# or
source ~/.bashrc     # if using bash
```

### Transcription is slow

1. Verify Whisper is running on GPU: check Activity Monitor for GPU usage
2. Try a smaller Whisper model: edit the installer and use `whisper-tiny-multilingual` instead

### No notes in my inbox

1. Check the `Desktop/Meeting Notes` folder — the file should be there
2. Make sure you've given Mail permission to send (macOS will prompt on first run)
3. Verify your email in the settings (check `~/Library/Application Support/MeetingNotes/config.json`)

### Model downloads failed

```bash
ollama pull qwen3:4b-instruct
ollama pull qwen2.5:7b
```

Then run `meeting` again.

---

## Project Structure

```
Meeting-Summarizer/
├── install.sh              # macOS installer
├── install-windows.ps1     # Windows installer
├── install-linux.sh        # Linux installer
├── notes.py                # Core transcription + summarization logic
└── README.md               # This file
```

After installation, files are stored in:

```
~/Library/Application Support/MeetingNotes/    # Config, venv, models
~/Desktop/Meeting Notes/                        # Your notes (one file per meeting)
```

---

## Requirements

- **macOS 11+** (Apple Silicon or Intel with Ollama)
- **Windows 10+** (with Python 3.9+)
- **Linux** (Ubuntu 20.04+ recommended, with PipeWire or PulseAudio)
- **~3 GB free disk space** (for models)
- **Internet** (one-time for downloads; offline after that)

---

## What's Under the Hood

This tool relies on two open-source models:

1. **Whisper** (OpenAI) — speech-to-text
   - Runs locally via MLX on Apple Silicon
   - ~78× faster than real time for transcription

2. **Llama 3.2 3B** (Meta) — text summarization
   - ~2 GB, optimized for summaries
   - Can swap for any larger model (Qwen, Llama 8B, etc.)

Both run via **Ollama**, a local AI runtime that requires no cloud connection.

---

## For Developers

Want to modify the setup, swap in a different model, or contribute? Everything is open source.

- The installer is a single bash/PowerShell/sh script — read it before you run it
- The notes engine is standard Python with no proprietary dependencies
- All models are downloaded from Hugging Face or Meta

Fork, break, improve. The only person who needs to approve your changes is you.

---

## FAQ

**Q: Does this work with Zoom, Teams, Google Meet, FaceTime?**  
A: Yes. Your Mac plays the call through its speakers and hears it through its mic. This tool captures that audio at the OS level, so it works with any meeting app.

**Q: What if I want to use a bigger model for fancier summaries?**  
A: Run `meeting qwen3:35b-mlx` or swap the default in the config. Same one-word command.

**Q: Can I run this on multiple Macs?**  
A: Install on each one independently. Each machine handles its own notes.

**Q: What happens to notes if I close the app mid-call?**  
A: Press **q** to stop recording cleanly. If you force-quit, the audio file is saved but won't be transcribed until you run the tool again.

**Q: Can I share notes with my team?**  
A: Your notes are Markdown files in `Desktop/Meeting Notes`. Email them, paste them, commit them — they're yours.

**Q: Is this HIPAA or SOC 2 compliant?**  
A: This tool runs entirely on your machine, so compliance depends on your broader setup. Audio never touches a third-party server, so that piece is inherently private.

---

## What This Really Buys You

It isn't about the $18 a month. It's that the most sensitive conversations you have — comp, reviews, legal, health, deals — finally get the same effortless AI treatment as everything else, **without you having to decide whether you trust a vendor with them.**

The old trade-off: *convenience or privacy.*

Now? You get both. And you get them for free, on hardware you already own.

---

## Next Steps

1. **Install:** Paste the one-liner for your OS above
2. **Configure:** Set your email when prompted
3. **Test:** Join a short call and run `meeting`
4. **Customize:** Swap models with `meeting --list` and pick a different one
5. **Share:** If this saved you an hour, star the repo and tell a friend

---

## License

Open source. See LICENSE file for details.

## Thanks

- OpenAI (Whisper)
- Meta (Llama)
- The MLX team (Apple Silicon acceleration)
- Ollama (easy local AI runtime)

---

**The cloud is convenient. Owning the whole thing is better.**
