from __future__ import annotations

import base64
import io
import math
import os
import shutil
import subprocess
import tempfile
import wave
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .providers import TTSProvider


@dataclass(frozen=True)
class AudioChunk:
    audio_id: str
    index: int
    data_b64: str
    mime_type: str = "audio/wav"
    encoding: str = "base64"


class DeterministicStubTTS:
    """Tiny deterministic TTS stand-in for tests and safety fallback.

    The output is a valid mono PCM WAV. It is intentionally not speech; use
    ``LOGOS_TTS_PROVIDER=macos_say`` for intelligible local speech on macOS.
    """

    sample_rate = 16_000
    mime_type = "audio/wav"
    source_name = "deterministic_stub_tts"

    def synthesize(self, text: str) -> bytes:
        text = str(text or "")
        # 300-900 ms, deterministic from text length. Short enough for tests,
        # audible enough in Simulator when host audio is enabled.
        duration_seconds = min(0.9, max(0.3, 0.18 + len(text) * 0.012))
        frequency = 440 + (sum(text.encode("utf-8")) % 220)
        frame_count = int(self.sample_rate * duration_seconds)
        buffer = io.BytesIO()
        with wave.open(buffer, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(self.sample_rate)
            for i in range(frame_count):
                envelope = min(1.0, i / 800, (frame_count - i) / 800 if frame_count > i else 0.0)
                sample = int(
                    0.25
                    * envelope
                    * 32767
                    * math.sin(2 * math.pi * frequency * (i / self.sample_rate))
                )
                wav.writeframesraw(sample.to_bytes(2, byteorder="little", signed=True))
        return buffer.getvalue()

    def iter_chunks(self, *, text: str, audio_id: str, chunk_size: int = 4096) -> list[AudioChunk]:
        return _chunk_audio(
            self.synthesize(text),
            audio_id=audio_id,
            chunk_size=chunk_size,
            mime_type=self.mime_type,
        )


class MacOSSayTTS:
    """Intelligible local TTS using macOS ``say`` and ``afconvert``.

    ``say`` produces an AIFF-C file. ``afconvert`` normalizes it to mono 16 kHz
    PCM WAV so the existing Logos chunked-audio protocol and iOS playback path
    keep working without extra Python audio dependencies.
    """

    sample_rate = 16_000
    mime_type = "audio/wav"
    source_name = "macos_say_tts"

    def __init__(
        self,
        *,
        voice: str | None = None,
        timeout_seconds: float = 20.0,
        runner: Callable[..., subprocess.CompletedProcess[bytes]] | None = None,
        say_path: str | None = None,
        afconvert_path: str | None = None,
    ) -> None:
        self.voice = str(voice or os.getenv("LOGOS_TTS_VOICE") or "").strip() or None
        self.timeout_seconds = max(1.0, float(timeout_seconds))
        self.runner = runner or _run_subprocess
        self.say_path = say_path or shutil.which("say") or "/usr/bin/say"
        self.afconvert_path = afconvert_path or shutil.which("afconvert") or "/usr/bin/afconvert"

    def synthesize(self, text: str) -> bytes:
        text = _clean_tts_text(text)
        if not text:
            text = "Hermes finished."
        with tempfile.TemporaryDirectory(prefix="logos-tts-") as tmpdir:
            base = Path(tmpdir)
            aiff_path = base / "speech.aiff"
            wav_path = base / "speech.wav"
            say_cmd = [self.say_path]
            if self.voice:
                say_cmd.extend(["-v", self.voice])
            say_cmd.extend(["-o", str(aiff_path), text])
            self.runner(say_cmd, timeout_seconds=self.timeout_seconds)
            convert_cmd = [
                self.afconvert_path,
                "-f",
                "WAVE",
                "-d",
                f"LEI16@{self.sample_rate}",
                str(aiff_path),
                str(wav_path),
            ]
            self.runner(convert_cmd, timeout_seconds=self.timeout_seconds)
            audio = wav_path.read_bytes()
        if not audio.startswith(b"RIFF"):
            raise RuntimeError("macOS say TTS did not produce a WAV RIFF file")
        return audio

    def iter_chunks(self, *, text: str, audio_id: str, chunk_size: int = 4096) -> list[AudioChunk]:
        return _chunk_audio(
            self.synthesize(text),
            audio_id=audio_id,
            chunk_size=chunk_size,
            mime_type=self.mime_type,
        )


def build_tts(extra: dict[str, Any] | None = None) -> TTSProvider:
    extra = dict(extra or {})
    provider = (
        str(os.getenv("LOGOS_TTS_PROVIDER") or extra.get("tts_provider") or "deterministic")
        .strip()
        .lower()
    )
    if provider in {"macos_say", "say", "local", "real"}:
        return MacOSSayTTS(
            voice=_optional_text(os.getenv("LOGOS_TTS_VOICE") or extra.get("tts_voice")),
            timeout_seconds=float(os.getenv("LOGOS_TTS_TIMEOUT") or extra.get("tts_timeout", 20.0)),
            runner=extra.get("tts_runner"),
            say_path=_optional_text(extra.get("say_path")),
            afconvert_path=_optional_text(extra.get("afconvert_path")),
        )
    return DeterministicStubTTS()


def _chunk_audio(
    audio: bytes, *, audio_id: str, chunk_size: int, mime_type: str
) -> list[AudioChunk]:
    chunks: list[AudioChunk] = []
    for index, start in enumerate(range(0, len(audio), int(chunk_size))):
        raw = audio[start : start + int(chunk_size)]
        chunks.append(
            AudioChunk(
                audio_id=audio_id,
                index=index,
                data_b64=base64.b64encode(raw).decode("ascii"),
                mime_type=mime_type,
            )
        )
    return chunks


def _run_subprocess(
    args: list[str], *, timeout_seconds: float
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        args,
        check=True,
        capture_output=True,
        timeout=timeout_seconds,
    )


def _clean_tts_text(text: str) -> str:
    return " ".join(str(text or "").split())


def _optional_text(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None
