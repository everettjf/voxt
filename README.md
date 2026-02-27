# Voxt

Voxt is a menu-bar macOS app for push-to-talk transcription.
Hold a global shortcut, speak, and Voxt pastes the result into the currently focused app while restoring your previous clipboard content.

https://github.com/user-attachments/assets/8fde004a-e07a-45fc-ae3c-8f8a216873d3

## How It Works

1. Press your global shortcut (default: `Control + Option`, long-press mode).
2. Speak while the floating overlay shows live audio level and partial text.
3. Release the shortcut (or tap again in tap mode) to finish and paste.

## Features

- Global hotkey transcription from any app.
- Two trigger modes: `Long Press (Release to End)` and `Tap (Press to Toggle)`.
- Two transcription engines:
  - `MLX Audio (On-device)` with downloadable local STT models.
  - `Direct Dictation` via `SFSpeechRecognizer`.
- Smart engine behavior: if MLX is selected but model is unavailable, Voxt falls back to Direct Dictation.
- Floating non-activating overlay with:
  - Animated waveform while recording.
  - Live scrolling transcription text.
  - Processing spinner during enhancement.
- Optional Apple Intelligence enhancement (`FoundationModels`) with editable system prompt.
- Model download manager with size prefetch, per-file progress, cancel, delete, cache validation, and optional Hugging Face China mirror (`https://hf-mirror.com`).
- Clipboard-safe paste flow (clipboard content is restored after simulated paste).
- Selectable microphone input device.
- Optional interaction sounds for start/end feedback.
- Optional local transcription history (pagination, copy, delete, clear all, and per-entry metadata).
- Menu-bar-first app behavior with optional `Launch at Login` and `Show in Dock`.

## Settings

Voxt currently provides five settings tabs:

- `General`
  - Input device selection.
  - Interaction sounds toggle.
  - Launch at login.
  - Show in Dock.
- `History`
  - Enable/disable local transcription history.
  - Browse, copy, delete entries.
  - Clear all history.
- `Model`
  - Select transcription engine (`MLX Audio` / `Direct Dictation`).
  - Manage MLX STT models (download/use/delete/cancel).
  - Configure enhancement mode (`Off` / `Apple Intelligence` / `Custom LLM`).
  - Configure enhancement prompt.
  - Manage Custom LLM model downloads.
  - Built-in transcription test area with sample text diffing.
- `Hotkey`
  - Record global shortcut.
  - Conflict hints for common macOS shortcuts.
  - Choose trigger mode (`Long Press` or `Tap`).
- `About`
  - Version, project links, license, acknowledgements.

## Supported Models

### MLX STT models

- `mlx-community/Qwen3-ASR-0.6B-4bit` (default)
- `mlx-community/Qwen3-ASR-1.7B-bf16`
- `mlx-community/Voxtral-Mini-4B-Realtime-2602-fp16`
- `mlx-community/parakeet-tdt-0.6b-v3`
- `mlx-community/GLM-ASR-Nano-2512-4bit`

### Custom LLM model options

- `Qwen/Qwen2-1.5B-Instruct` (default)
- `Qwen/Qwen2.5-3B-Instruct`

## Current Limitation

- `Custom LLM` enhancement mode has model management UI, but the active enhancement pipeline currently applies only Apple Intelligence enhancement.

## Data & Privacy

- MLX STT transcription runs fully on-device. Direct Dictation uses Apple Speech framework behavior.
- Optional history is stored locally at:
  - `~/Library/Application Support/Voxt/transcription-history.json`

## Requirements

- macOS `26.0+` (project deployment target).
- Xcode `26+`.
- Microphone permission.
- Accessibility permission (for global hotkey monitoring and simulated paste).
- Speech Recognition permission when using `Direct Dictation`.

## Build

Open `Voxt.xcodeproj` in Xcode and build.

Or from terminal:

```bash
xcodebuild -project Voxt.xcodeproj -scheme Voxt -destination 'platform=macOS' build
```

## License

MIT
