from __future__ import annotations

import base64

import pytest

from gateway.config import PlatformConfig
from logos.adapter import LogosAdapter
from logos.schema import Envelope
from logos.tts import DeterministicStubTTS


class FakeServer:
    def __init__(self) -> None:
        self.frames: list[dict] = []

    async def broadcast(self, frame: dict, *, project_key: str | None = None) -> None:
        self.frames.append({"frame": frame, "project_key": project_key})


def test_deterministic_stub_tts_produces_valid_wav_chunks():
    tts = DeterministicStubTTS()
    first = tts.synthesize("hello")
    second = tts.synthesize("hello")
    assert first == second
    assert first.startswith(b"RIFF")
    chunks = tts.iter_chunks(text="hello", audio_id="audio-test", chunk_size=128)
    assert len(chunks) > 1
    assert b"".join(base64.b64decode(chunk.data_b64) for chunk in chunks) == first


@pytest.mark.asyncio
async def test_playback_audio_streams_chunks_and_end_frame_from_message(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]
    message = adapter.store.append_message(
        project_key="alpha",
        session_id="sess-alpha",
        role="assistant",
        content="Short answer for playback",
        message_id="msg-1",
    )

    response = await adapter.handle_ws_envelope(
        Envelope(
            type="playback_audio",
            request_id="play-1",
            device_id="iphone",
            project_key="alpha",
            session_id="sess-alpha",
            payload={"message_id": message.message_id, "audio_id": "audio-1", "mode": "summary"},
        )
    )

    assert response is None
    audio_chunks = [item["frame"] for item in fake_server.frames if item["frame"]["type"] == "audio_chunk"]
    audio_end = [item["frame"] for item in fake_server.frames if item["frame"]["type"] == "audio_end"]
    assert audio_chunks
    assert len(audio_end) == 1
    assert audio_end[0]["payload"]["audio_id"] == "audio-1"
    assert audio_end[0]["payload"]["chunk_count"] == len(audio_chunks)
    assert audio_chunks[0]["payload"]["mime_type"] == "audio/wav"
    assert base64.b64decode(audio_chunks[0]["payload"]["data"])
    assert [frame["server_seq"] for frame in audio_chunks + audio_end] == sorted(frame["server_seq"] for frame in audio_chunks + audio_end)


@pytest.mark.asyncio
async def test_playback_audio_returns_error_when_source_missing(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    response = await adapter.handle_ws_envelope(
        Envelope(
            type="playback_audio",
            request_id="play-missing",
            device_id="iphone",
            project_key="alpha",
            payload={},
        )
    )
    assert response is not None
    assert response["type"] == "error"
    assert response["payload"]["code"] == "missing_audio_source"
