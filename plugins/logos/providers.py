"""Structural Protocols for the Logos adapter's swappable backends.

These describe the fast-LLM and TTS provider surfaces the adapter depends on, so the
concrete implementations in fast_llm.py / tts.py (and test fakes) can be swapped without
the adapter importing concrete result types. Pure typing — no runtime behavior. The
existing concrete classes satisfy these structurally with no changes.
"""

from __future__ import annotations

from typing import Any, Protocol, Sequence, runtime_checkable


class FastModelResultLike(Protocol):
    ack: bool
    ack_text: str | None
    switch_intent: dict[str, str] | None
    create_intent: dict[str, str] | None
    resume_intent: dict[str, str] | None
    cancel_intent: bool
    approval_decision: str | None
    confidence: float

    def to_protocol(self) -> dict[str, Any]: ...


class SummaryResultLike(Protocol):
    summary_text: str

    def to_protocol(self) -> dict[str, Any]: ...


class ErrorExplanationLike(Protocol):
    message_text: str

    def to_protocol(self) -> dict[str, Any]: ...


@runtime_checkable
class FastLLMProvider(Protocol):
    provider_name: str

    def analyze_input(self, text: str, *, projects: list[str] | None = ...) -> FastModelResultLike: ...

    def summarize(self, text: str) -> SummaryResultLike: ...

    def explain_error(self, text: str) -> ErrorExplanationLike: ...


class AudioChunkLike(Protocol):
    index: int
    data_b64: str
    mime_type: str
    encoding: str


@runtime_checkable
class TTSProvider(Protocol):
    source_name: str

    def iter_chunks(self, *, text: str, audio_id: str, chunk_size: int = ...) -> Sequence[AudioChunkLike]: ...
