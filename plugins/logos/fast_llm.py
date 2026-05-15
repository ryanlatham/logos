from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from typing import Any


_SECRET_PATTERNS = [
    re.compile(r"sk-[A-Za-z0-9_-]{6,}"),
    re.compile(r"gh[pousr]_[A-Za-z0-9_]{10,}"),
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{10,}"),
]


@dataclass(frozen=True)
class FastModelResult:
    ack: bool
    ack_text: str | None
    switch_intent: dict[str, str] | None
    create_intent: dict[str, str] | None
    resume_intent: dict[str, str] | None
    cancel_intent: bool
    approval_decision: str | None
    confidence: float

    def to_protocol(self) -> dict[str, Any]:
        return {
            "ack": self.ack,
            "ack_text": self.ack_text,
            "switch_intent": self.switch_intent,
            "create_intent": self.create_intent,
            "resume_intent": self.resume_intent,
            "cancel_intent": self.cancel_intent,
            "approval_decision": self.approval_decision,
            "confidence": self.confidence,
        }


@dataclass(frozen=True)
class SummaryResult:
    summary_text: str
    source_hash: str
    source_chars: int

    def to_protocol(self) -> dict[str, Any]:
        return {
            "summary_text": self.summary_text,
            "source_hash": self.source_hash,
            "source_chars": self.source_chars,
        }


def parse_fast_model_json(raw: str | bytes | dict[str, Any]) -> FastModelResult:
    if isinstance(raw, dict):
        data = raw
    else:
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ValueError(f"fast model output is not valid JSON: {exc.msg}") from exc
    if not isinstance(data, dict):
        raise ValueError("fast model output must be a JSON object")

    ack = data.get("ack", False)
    if not isinstance(ack, bool):
        raise ValueError("fast model field ack must be a boolean")
    ack_text = _optional_nonempty_str(data.get("ack_text"), "ack_text")
    cancel_intent = data.get("cancel_intent", False)
    if not isinstance(cancel_intent, bool):
        raise ValueError("fast model field cancel_intent must be a boolean")
    confidence = data.get("confidence", 0.0)
    if not isinstance(confidence, (int, float)) or not 0.0 <= float(confidence) <= 1.0:
        raise ValueError("fast model confidence must be a number between 0 and 1")
    approval_decision = _optional_nonempty_str(data.get("approval_decision"), "approval_decision")
    if approval_decision is not None:
        approval_decision = approval_decision.lower()
        if approval_decision not in {"approve", "deny"}:
            raise ValueError("approval_decision must be approve, deny, or null")

    return FastModelResult(
        ack=ack,
        ack_text=ack_text,
        switch_intent=_optional_str_dict(data.get("switch_intent"), "switch_intent"),
        create_intent=_optional_str_dict(data.get("create_intent"), "create_intent"),
        resume_intent=_optional_str_dict(data.get("resume_intent"), "resume_intent"),
        cancel_intent=cancel_intent,
        approval_decision=approval_decision,
        confidence=float(confidence),
    )


def sanitize_summary_text(text: str) -> str:
    sanitized = str(text or "")
    for pattern in _SECRET_PATTERNS:
        sanitized = pattern.sub(lambda match: (match.group(1) if match.lastindex else "") + "[REDACTED]", sanitized)
    sanitized = re.sub(r"\s+", " ", sanitized).strip()
    return sanitized


class DeterministicFastModel:
    """Strict, deterministic Stage H fallback for ack, safe intents, and summaries.

    This is intentionally conservative. It only emits control intents for narrow,
    low-ambiguity utterance shapes; everything else returns an ack and lets Hermes
    handle the text normally.
    """

    def __init__(self, *, summary_max_chars: int = 240) -> None:
        self.summary_max_chars = max(40, int(summary_max_chars))

    def analyze_input(self, text: str, *, projects: list[str] | None = None) -> FastModelResult:
        raw_text = str(text or "").strip()
        normalized = re.sub(r"\s+", " ", raw_text.lower()).strip()
        ack_text = self._ack_text(normalized)
        switch_intent: dict[str, str] | None = None
        create_intent: dict[str, str] | None = None
        resume_intent: dict[str, str] | None = None
        cancel_intent = False
        approval_decision: str | None = None
        confidence = 0.58 if raw_text else 0.0

        if normalized in {"stop", "cancel", "never mind", "nevermind", "halt", "abort"}:
            cancel_intent = True
            ack_text = "Stopping."
            confidence = 0.98
        elif normalized in {"approve", "approved", "yes approve", "proceed", "go ahead", "allow"}:
            approval_decision = "approve"
            ack_text = "Approved."
            confidence = 0.97
        elif normalized in {"deny", "denied", "reject", "no deny", "do not approve", "don't approve"} or normalized.startswith("deny "):
            approval_decision = "deny"
            ack_text = "Denied."
            confidence = 0.97
        else:
            match = re.fullmatch(r"(?:switch|change|move) (?:to|into) (?:project )?(.+)", normalized)
            if match:
                title = _clean_title(match.group(1))
                if title:
                    switch_intent = {"project_title": title}
                    ack_text = f"Switching to {title}."
                    confidence = 0.88
            match = re.fullmatch(r"(?:create|new|start) (?:a )?(?:new )?project(?: called| named)? (.+)", normalized)
            if match:
                title = _clean_title(match.group(1))
                if title:
                    create_intent = {"title": title}
                    ack_text = f"Creating {title}."
                    confidence = 0.9
            match = re.fullmatch(r"resume (?:project |session )?(.+)", normalized)
            if match:
                target = _clean_title(match.group(1))
                if target:
                    resume_intent = {"target": target}
                    ack_text = f"Resuming {target}."
                    confidence = 0.9

        return FastModelResult(
            ack=bool(raw_text),
            ack_text=ack_text if raw_text else None,
            switch_intent=switch_intent,
            create_intent=create_intent,
            resume_intent=resume_intent,
            cancel_intent=cancel_intent,
            approval_decision=approval_decision,
            confidence=confidence,
        )

    def summarize(self, text: str) -> SummaryResult:
        original = str(text or "")
        source_hash = hashlib.sha256(original.encode("utf-8")).hexdigest()
        sanitized = sanitize_summary_text(original)
        if not sanitized:
            sanitized = "Hermes finished."
        first_sentence = _first_sentence(sanitized)
        summary = first_sentence or sanitized
        if len(summary) > self.summary_max_chars:
            summary = summary[: max(0, self.summary_max_chars - 1)].rstrip() + "…"
        return SummaryResult(
            summary_text=summary,
            source_hash=source_hash,
            source_chars=len(original),
        )

    @staticmethod
    def _ack_text(normalized: str) -> str:
        if not normalized:
            return ""
        if normalized.startswith(("check", "look", "inspect")):
            return "I'll check."
        if normalized.startswith(("build", "run", "test")):
            return "On it."
        return "Got it."


def _optional_nonempty_str(value: Any, field_name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f"{field_name} must be a string or null")
    stripped = value.strip()
    return stripped or None


def _optional_str_dict(value: Any, field_name: str) -> dict[str, str] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError(f"{field_name} must be an object or null")
    result: dict[str, str] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not isinstance(item, str) or not item.strip():
            raise ValueError(f"{field_name} must contain only non-empty string values")
        result[key] = item.strip()
    return result or None


def _clean_title(text: str) -> str:
    cleaned = re.sub(r"\s+", " ", str(text or "").strip(" .!?\t\n\r"))
    return cleaned


def _first_sentence(text: str) -> str:
    match = re.search(r"(.+?[.!?])(?:\s|$)", text)
    return match.group(1).strip() if match else text.strip()
