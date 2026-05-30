"""Structural Protocols for the Logos adapter's swappable backends.

These describe the fast-LLM and TTS provider surfaces the adapter depends on, so the
concrete implementations in fast_llm.py / tts.py (and test fakes) can be swapped without
the adapter importing concrete result types. Pure typing — no runtime behavior. The
existing concrete classes satisfy these structurally with no changes.

The result-object members are declared as read-only ``@property`` rather than bare
annotations so that the (frozen, immutable) concrete result dataclasses satisfy them
covariantly — this is what lets ``list[AudioChunk]`` count as ``Sequence[AudioChunkLike]``
and ``FastModelResult`` count as ``FastModelResultLike`` under strict typing. The adapter
only ever reads these members, never assigns through the protocol-typed reference.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any, Protocol, runtime_checkable


class FastModelResultLike(Protocol):
    @property
    def ack(self) -> bool: ...
    @property
    def ack_text(self) -> str | None: ...
    @property
    def direct_response_text(self) -> str | None: ...
    @property
    def direct_response_kind(self) -> str | None: ...
    @property
    def switch_intent(self) -> dict[str, str] | None: ...
    @property
    def create_intent(self) -> dict[str, str] | None: ...
    @property
    def resume_intent(self) -> dict[str, str] | None: ...
    @property
    def cancel_intent(self) -> bool: ...
    @property
    def approval_decision(self) -> str | None: ...
    @property
    def confidence(self) -> float: ...

    def to_protocol(self) -> dict[str, Any]: ...


class SummaryResultLike(Protocol):
    @property
    def summary_text(self) -> str: ...

    def to_protocol(self) -> dict[str, Any]: ...


class ErrorExplanationLike(Protocol):
    @property
    def message_text(self) -> str: ...

    def to_protocol(self) -> dict[str, Any]: ...


@runtime_checkable
class FastLLMProvider(Protocol):
    @property
    def provider_name(self) -> str: ...

    def analyze_input(
        self, text: str, *, projects: list[str] | None = ...
    ) -> FastModelResultLike: ...

    def summarize(self, text: str) -> SummaryResultLike: ...

    def explain_error(self, text: str) -> ErrorExplanationLike: ...


class AudioChunkLike(Protocol):
    @property
    def index(self) -> int: ...
    @property
    def data_b64(self) -> str: ...
    @property
    def mime_type(self) -> str: ...
    @property
    def encoding(self) -> str: ...


@runtime_checkable
class TTSProvider(Protocol):
    @property
    def source_name(self) -> str: ...

    def iter_chunks(
        self, *, text: str, audio_id: str, chunk_size: int = ...
    ) -> Sequence[AudioChunkLike]: ...
