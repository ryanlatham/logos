from __future__ import annotations

import base64
import io
import math
import wave
from dataclasses import dataclass


@dataclass(frozen=True)
class AudioChunk:
    audio_id: str
    index: int
    data_b64: str
    mime_type: str = "audio/wav"
    encoding: str = "base64"


class DeterministicStubTTS:
    """Tiny deterministic TTS stand-in used until a real local TTS runtime is available.

    The output is a valid mono PCM WAV. It is intentionally not speech; it proves
    protocol, chunking, transfer, caching seams, and iOS playback without pulling
    Kokoro/model packaging into the critical path.
    """

    sample_rate = 16_000
    mime_type = "audio/wav"

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
                sample = int(0.25 * envelope * 32767 * math.sin(2 * math.pi * frequency * (i / self.sample_rate)))
                wav.writeframesraw(sample.to_bytes(2, byteorder="little", signed=True))
        return buffer.getvalue()

    def iter_chunks(self, *, text: str, audio_id: str, chunk_size: int = 4096) -> list[AudioChunk]:
        audio = self.synthesize(text)
        chunks: list[AudioChunk] = []
        for index, start in enumerate(range(0, len(audio), chunk_size)):
            raw = audio[start : start + chunk_size]
            chunks.append(
                AudioChunk(
                    audio_id=audio_id,
                    index=index,
                    data_b64=base64.b64encode(raw).decode("ascii"),
                    mime_type=self.mime_type,
                )
            )
        return chunks
