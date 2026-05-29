"""The concrete fast-model / TTS backends must satisfy the provider Protocols (Hermes-free)."""

from __future__ import annotations

from logos.fast_llm import DeterministicFastModel
from logos.providers import FastLLMProvider, TTSProvider
from logos.tts import DeterministicStubTTS


def test_deterministic_fast_model_satisfies_protocol():
    assert isinstance(DeterministicFastModel(), FastLLMProvider)


def test_deterministic_tts_satisfies_protocol():
    assert isinstance(DeterministicStubTTS(), TTSProvider)
