from __future__ import annotations

import base64
import subprocess

import pytest

from gateway.config import PlatformConfig
from logos.adapter import LogosAdapter
from logos.schema import Envelope
from logos.tts import DeterministicStubTTS, MacOSSayTTS, build_tts


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


def test_macos_say_tts_uses_configured_runner_and_chunks_speech():
    spoken_wav = DeterministicStubTTS().synthesize("spoken words")
    calls: list[list[str]] = []

    def fake_runner(args, *, timeout_seconds):
        calls.append(list(args))
        if args[0].endswith("say"):
            output = args[args.index("-o") + 1]
            open(output, "wb").write(b"fake-aiff")
        elif args[0].endswith("afconvert"):
            open(args[-1], "wb").write(spoken_wav)
        return subprocess.CompletedProcess(args=args, returncode=0)

    tts = MacOSSayTTS(runner=fake_runner, timeout_seconds=1)
    audio = tts.synthesize("hello from Logos")
    assert audio.startswith(b"RIFF")
    assert any(call[0].endswith("say") for call in calls)
    assert any(call[0].endswith("afconvert") for call in calls)
    chunks = tts.iter_chunks(text="hello from Logos", audio_id="real-audio", chunk_size=128)
    assert b"".join(base64.b64decode(chunk.data_b64) for chunk in chunks) == spoken_wav


def test_macos_say_tts_does_not_truncate_long_full_response_text():
    spoken_wav = DeterministicStubTTS().synthesize("long spoken words")
    calls: list[list[str]] = []

    def fake_runner(args, *, timeout_seconds):
        calls.append(list(args))
        if args[0].endswith("say"):
            output = args[args.index("-o") + 1]
            open(output, "wb").write(b"fake-aiff")
        elif args[0].endswith("afconvert"):
            open(args[-1], "wb").write(spoken_wav)
        return subprocess.CompletedProcess(args=args, returncode=0)

    long_text = " ".join(f"word{index}" for index in range(250))
    tts = MacOSSayTTS(runner=fake_runner, timeout_seconds=1)

    assert tts.synthesize(long_text).startswith(b"RIFF")

    say_call = next(call for call in calls if call[0].endswith("say"))
    assert say_call[-1] == long_text
    assert len(say_call[-1]) > 1200


def test_build_tts_selects_configured_real_provider(monkeypatch):
    monkeypatch.setenv("LOGOS_TTS_PROVIDER", "macos_say")
    tts = build_tts({"tts_runner": lambda args, *, timeout_seconds: subprocess.CompletedProcess(args=args, returncode=0)})
    assert isinstance(tts, MacOSSayTTS)


class RecordingTTS:
    source_name = "recording_tts"

    def __init__(self) -> None:
        self.texts: list[str] = []

    def iter_chunks(self, *, text: str, audio_id: str):
        self.texts.append(text)
        return DeterministicStubTTS().iter_chunks(text=text, audio_id=audio_id, chunk_size=128)


@pytest.mark.asyncio
async def test_playback_audio_full_mode_speaks_complete_stored_message(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]
    recording_tts = RecordingTTS()
    adapter.tts = recording_tts
    message = adapter.store.append_message(
        project_key="alpha",
        session_id="sess-alpha",
        role="assistant",
        content="First sentence. Second sentence must also be spoken. Third sentence too.",
        message_id="msg-full",
    )

    response = await adapter.handle_ws_envelope(
        Envelope(
            type="playback_audio",
            request_id="play-full",
            device_id="iphone",
            project_key="alpha",
            session_id="sess-alpha",
            payload={"message_id": message.message_id, "audio_id": "audio-full", "mode": "full", "text": "stale local text"},
        )
    )

    assert response is None
    assert recording_tts.texts == [message.content]
    audio_end = [item["frame"] for item in fake_server.frames if item["frame"]["type"] == "audio_end"]
    assert len(audio_end) == 1
    assert audio_end[0]["payload"]["mode"] == "full"


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


@pytest.mark.asyncio
async def test_tts_failure_response_and_logs_do_not_leak_spoken_text(tmp_path, caplog):
    secret_token = "sk-" + "test-secret-12345"
    private_text = f"private transcript {secret_token}"

    class FailingTTS:
        source_name = "failing_tts"

        def iter_chunks(self, *, text: str, audio_id: str):
            raise subprocess.CalledProcessError(1, ["/usr/bin/say", "-o", "/tmp/out.aiff", text])

    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    adapter.tts = FailingTTS()
    message = adapter.store.append_message(
        project_key="alpha",
        session_id="sess-alpha",
        role="assistant",
        content=private_text,
        message_id="msg-private",
    )
    caplog.set_level("WARNING", logger="logos.adapter")

    response = await adapter.handle_ws_envelope(
        Envelope(
            type="playback_audio",
            request_id="play-private",
            device_id="iphone",
            project_key="alpha",
            session_id="sess-alpha",
            payload={"message_id": message.message_id, "audio_id": "audio-private", "mode": "full"},
        )
    )

    assert response is not None
    assert response["type"] == "error"
    assert response["payload"]["code"] == "tts_failed"
    combined = response["payload"]["message"] + "\n" + caplog.text
    assert private_text not in combined
    assert secret_token not in combined
    assert "CalledProcessError" in response["payload"]["message"]
