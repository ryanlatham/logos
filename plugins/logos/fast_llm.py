from __future__ import annotations

import hashlib
import json
import os
import re
import urllib.error
import urllib.request
from dataclasses import dataclass, replace
from typing import Any, Callable


_SECRET_PATTERNS = [
    re.compile(r"sk-[A-Za-z0-9_-]{6,}"),
    re.compile(r"gh[pousr]_[A-Za-z0-9_]{10,}"),
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{10,}"),
]

OllamaTransport = Callable[..., str]


@dataclass(frozen=True)
class FastModelResult:
    ack: bool
    ack_text: str | None
    direct_response_text: str | None
    direct_response_kind: str | None
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
            "direct_response_text": self.direct_response_text,
            "direct_response_kind": self.direct_response_kind,
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


@dataclass(frozen=True)
class ErrorExplanationResult:
    message_text: str
    source_hash: str
    source_chars: int

    def to_protocol(self) -> dict[str, Any]:
        return {
            "message_text": self.message_text,
            "source_hash": self.source_hash,
            "source_chars": self.source_chars,
        }


def parse_fast_model_json(raw: str | bytes | dict[str, Any]) -> FastModelResult:
    if isinstance(raw, dict):
        data = raw
    else:
        try:
            data = json.loads(_extract_json_object(raw.decode("utf-8") if isinstance(raw, bytes) else str(raw)))
        except json.JSONDecodeError as exc:
            raise ValueError(f"fast model output is not valid JSON: {exc.msg}") from exc
    if not isinstance(data, dict):
        raise ValueError("fast model output must be a JSON object")

    ack = data.get("ack", False)
    if not isinstance(ack, bool):
        raise ValueError("fast model field ack must be a boolean")
    ack_text = _optional_nonempty_str(data.get("ack_text"), "ack_text")
    direct_response_text = sanitize_direct_response_text(_optional_nonempty_str(data.get("direct_response_text"), "direct_response_text"))
    direct_response_kind = _optional_nonempty_str(data.get("direct_response_kind"), "direct_response_kind")
    if direct_response_kind is not None:
        direct_response_kind = direct_response_kind.lower()
        if direct_response_kind not in DIRECT_RESPONSE_KINDS:
            raise ValueError("direct_response_kind must be social, app_help, simple_text, or null")
    if direct_response_text and direct_response_kind is None:
        raise ValueError("direct_response_kind is required when direct_response_text is present")
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
    switch_intent = _optional_str_dict(data.get("switch_intent"), "switch_intent")
    create_intent = _optional_str_dict(data.get("create_intent"), "create_intent")
    resume_intent = _optional_str_dict(data.get("resume_intent"), "resume_intent")
    if direct_response_text and any([switch_intent, create_intent, resume_intent, cancel_intent, approval_decision]):
        raise ValueError("direct_response_text cannot be combined with control or approval intents")

    return FastModelResult(
        ack=ack,
        ack_text=ack_text,
        direct_response_text=direct_response_text,
        direct_response_kind=direct_response_kind if direct_response_text else None,
        switch_intent=switch_intent,
        create_intent=create_intent,
        resume_intent=resume_intent,
        cancel_intent=cancel_intent,
        approval_decision=approval_decision,
        confidence=float(confidence),
    )


def parse_summary_json(raw: str | bytes | dict[str, Any], *, source_text: str, summary_max_chars: int) -> SummaryResult:
    if isinstance(raw, dict):
        data = raw
    else:
        try:
            data = json.loads(_extract_json_object(raw.decode("utf-8") if isinstance(raw, bytes) else str(raw)))
        except json.JSONDecodeError as exc:
            raise ValueError(f"summary model output is not valid JSON: {exc.msg}") from exc
    if not isinstance(data, dict):
        raise ValueError("summary model output must be a JSON object")
    summary_text = _optional_nonempty_str(data.get("summary_text"), "summary_text")
    if not summary_text:
        raise ValueError("summary_text is required")
    summary = sanitize_summary_text(summary_text)
    if len(summary) > summary_max_chars:
        summary = summary[: max(0, summary_max_chars - 1)].rstrip() + "…"
    original = str(source_text or "")
    return SummaryResult(
        summary_text=summary,
        source_hash=hashlib.sha256(original.encode("utf-8")).hexdigest(),
        source_chars=len(original),
    )


def parse_error_explanation_json(raw: str | bytes | dict[str, Any], *, source_text: str) -> ErrorExplanationResult:
    if isinstance(raw, dict):
        data = raw
    else:
        try:
            data = json.loads(_extract_json_object(raw.decode("utf-8") if isinstance(raw, bytes) else str(raw)))
        except json.JSONDecodeError as exc:
            raise ValueError(f"error explanation model output is not valid JSON: {exc.msg}") from exc
    if not isinstance(data, dict):
        raise ValueError("error explanation model output must be a JSON object")
    message_text = sanitize_error_explanation_text(_optional_nonempty_str(data.get("message_text"), "message_text"))
    if not message_text:
        raise ValueError("message_text is required")
    original = str(source_text or "")
    return ErrorExplanationResult(
        message_text=message_text,
        source_hash=hashlib.sha256(original.encode("utf-8")).hexdigest(),
        source_chars=len(original),
    )


def sanitize_summary_text(text: str) -> str:
    sanitized = str(text or "")
    for pattern in _SECRET_PATTERNS:
        sanitized = pattern.sub(lambda match: (match.group(1) if match.lastindex else "") + "[REDACTED]", sanitized)
    sanitized = re.sub(r"\s+", " ", sanitized).strip()
    return sanitized


MAX_ERROR_EXPLANATION_CHARS = 420


def sanitize_error_explanation_text(text: str | None) -> str | None:
    if text is None:
        return None
    sanitized = sanitize_summary_text(text).replace("```", "").strip()
    if len(sanitized) > MAX_ERROR_EXPLANATION_CHARS:
        sanitized = sanitized[: max(0, MAX_ERROR_EXPLANATION_CHARS - 1)].rstrip() + "…"
    return sanitized or None


DIRECT_RESPONSE_KINDS = {"social", "app_help", "simple_text"}
GENERIC_ACK_TEXTS = {"got it", "got it.", "sure", "sure.", "okay", "okay.", "ok", "ok."}
MAX_ACK_CHARS = 80
MAX_DIRECT_RESPONSE_CHARS = 240


def sanitize_direct_response_text(text: str | None) -> str | None:
    if text is None:
        return None
    sanitized = sanitize_summary_text(text).replace("```", "").strip()
    if len(sanitized) > MAX_DIRECT_RESPONSE_CHARS:
        sanitized = sanitized[: max(0, MAX_DIRECT_RESPONSE_CHARS - 1)].rstrip() + "…"
    return sanitized or None


def sanitize_ack_text(text: str | None) -> str | None:
    if text is None:
        return None
    sanitized = sanitize_summary_text(text).replace("```", "").strip()
    if len(sanitized) > MAX_ACK_CHARS:
        sanitized = sanitized[: max(0, MAX_ACK_CHARS - 1)].rstrip() + "…"
    return sanitized or None


def natural_ack_for(text: str) -> str:
    normalized = re.sub(r"\s+", " ", str(text or "").strip().lower())
    normalized = re.sub(r"^(please|can you|could you|would you|will you)\s+", "", normalized)
    if not normalized:
        return ""
    if normalized.startswith(("check", "look", "inspect", "find", "search")):
        return "I'll check."
    if normalized.startswith(("build", "run", "test")):
        return "On it."
    if normalized.startswith(("fix", "update", "change", "make", "edit", "patch")):
        return "I'll handle it."
    if normalized.startswith(("debug", "diagnose", "investigate", "figure out", "why")):
        return "I'll take a look."
    if normalized.startswith("summarize"):
        return "I'll condense it."
    if normalized.startswith("explain"):
        return "I'll explain."
    choices = ["On it.", "I'll take a look.", "Working on it.", "I'll handle it."]
    digest = hashlib.sha256(normalized.encode("utf-8")).digest()
    return choices[digest[0] % len(choices)]


def _deterministic_direct_response(normalized: str) -> tuple[str, str] | None:
    allowed_kind = direct_response_kind_for_request(normalized)
    if allowed_kind is None:
        return None
    if allowed_kind == "social":
        if normalized in {"hi", "hello", "hey", "hi ada", "hello ada", "hey ada", "hello there"}:
            return "I'm here. What are we tackling?", "social"
        if normalized in {"thanks", "thank you", "thx", "ty", "appreciate it"}:
            return "Anytime.", "social"
        if normalized in {"you there?", "you there", "are you there?", "are you there", "ada?"}:
            return "I'm here.", "social"
    if allowed_kind == "app_help":
        if normalized in {"who are you?", "who are you", "what are you?", "what are you"}:
            return "I'm Ada, your Logos assistant in this app.", "app_help"
        if normalized in {
            "what can you do from this app?",
            "what can you do from this app",
            "what can you do here?",
            "what can you do here",
            "help",
        }:
            return "I can send requests to Hermes, switch projects, handle approvals, and play responses back.", "app_help"
        if re.fullmatch(r"how (?:do|can) i (?:stop|cancel)(?: a| the)? run\??", normalized):
            return "Tap Stop, or say “stop”.", "app_help"
    if allowed_kind == "simple_text" and normalized in {"say hello", "say hello back"}:
        return "Hello.", "simple_text"
    return None


def direct_response_kind_for_request(text: str) -> str | None:
    normalized = re.sub(r"\s+", " ", str(text or "").strip().lower())
    if not normalized or normalized.startswith("/"):
        return None
    if normalized in {"hi", "hello", "hey", "hi ada", "hello ada", "hey ada", "hello there"}:
        return "social"
    if normalized in {"thanks", "thank you", "thx", "ty", "appreciate it"}:
        return "social"
    if normalized in {"you there?", "you there", "are you there?", "are you there", "ada?"}:
        return "social"
    if normalized in {"who are you?", "who are you", "what are you?", "what are you"}:
        return "app_help"
    if normalized in {
        "what can you do from this app?",
        "what can you do from this app",
        "what can you do here?",
        "what can you do here",
        "help",
    }:
        return "app_help"
    if re.fullmatch(r"how (?:do|can) i (?:stop|cancel)(?: a| the)? run\??", normalized):
        return "app_help"
    if normalized in {"say hello", "say hello back"}:
        return "simple_text"
    return None


def _direct_response_text_is_safe(text: str | None) -> bool:
    normalized = re.sub(r"\s+", " ", str(text or "").strip().lower())
    if not normalized:
        return False
    privileged_starts = (
        "approved",
        "denied",
        "rejected",
        "stopped",
        "cancelled",
        "canceled",
        "switched",
        "created",
        "resumed",
        "running",
        "done",
        "completed",
        "i approved",
        "i denied",
        "i stopped",
        "i switched",
        "i created",
        "i resumed",
    )
    return not normalized.startswith(privileged_starts)


def is_safe_direct_response_for_request(text: str, response_kind: str | None, response_text: str | None) -> bool:
    allowed_kind = direct_response_kind_for_request(text)
    return allowed_kind is not None and response_kind == allowed_kind and _direct_response_text_is_safe(response_text)


def _is_direct_response_request_safe(text: str) -> bool:
    return direct_response_kind_for_request(text) is not None


class DeterministicFastModel:
    """Strict, deterministic fallback for ack, safe intents, and summaries.

    This remains the test double and safety fallback. Production Logos can use a
    local fast LLM via :class:`OllamaFastModel`; malformed/slow/low-confidence
    model output falls back here instead of blocking the main Hermes response.
    """

    provider_name = "deterministic"

    def __init__(self, *, summary_max_chars: int = 240) -> None:
        self.summary_max_chars = max(40, int(summary_max_chars))

    def analyze_input(self, text: str, *, projects: list[str] | None = None) -> FastModelResult:
        raw_text = str(text or "").strip()
        normalized = re.sub(r"\s+", " ", raw_text.lower()).strip()
        ack_text = natural_ack_for(raw_text)
        direct_response_text: str | None = None
        direct_response_kind: str | None = None
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
            if not any([switch_intent, create_intent, resume_intent]):
                direct = _deterministic_direct_response(normalized)
                if direct is not None:
                    direct_response_text, direct_response_kind = direct
                    ack_text = None
                    confidence = 0.95

        has_direct_response = direct_response_text is not None
        return FastModelResult(
            ack=bool(raw_text) and not has_direct_response,
            ack_text=ack_text if raw_text and not has_direct_response else None,
            direct_response_text=direct_response_text,
            direct_response_kind=direct_response_kind,
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

    def explain_error(self, text: str) -> ErrorExplanationResult:
        original = str(text or "")
        source_hash = hashlib.sha256(original.encode("utf-8")).hexdigest()
        raw = sanitize_summary_text(original).lstrip("⚠️⚠❌ ").strip()
        if not raw:
            raw = "an internal error"
        message = (
            "Hermes hit an unrecoverable error before it could answer. "
            f"The underlying error was: {raw}. "
            "Please retry, or switch models if it keeps happening."
        )
        return ErrorExplanationResult(
            message_text=sanitize_error_explanation_text(message) or "Hermes hit an unrecoverable error before it could answer.",
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


class OllamaFastModel:
    """Configurable local fast-model client backed by Ollama's generate API."""

    provider_name = "ollama"

    def __init__(
        self,
        *,
        endpoint: str | None = None,
        model: str | None = None,
        timeout_seconds: float = 2.5,
        min_confidence: float = 0.55,
        direct_response_min_confidence: float = 0.86,
        summary_max_chars: int = 240,
        transport: OllamaTransport | None = None,
        fallback: DeterministicFastModel | None = None,
    ) -> None:
        self.endpoint = (endpoint or os.getenv("OLLAMA_HOST") or os.getenv("LOGOS_FAST_MODEL_ENDPOINT") or "http://127.0.0.1:11434").rstrip("/")
        self.model = model or os.getenv("LOGOS_FAST_MODEL_MODEL") or os.getenv("OLLAMA_MODEL") or "gemma3:12b"
        self.timeout_seconds = max(0.1, float(timeout_seconds))
        self.min_confidence = min(1.0, max(0.0, float(min_confidence)))
        self.direct_response_min_confidence = min(1.0, max(0.0, float(direct_response_min_confidence)))
        self.summary_max_chars = max(40, int(summary_max_chars))
        self.transport = transport or ollama_generate
        self.fallback = fallback or DeterministicFastModel(summary_max_chars=self.summary_max_chars)
        self.last_error: str | None = None

    def analyze_input(self, text: str, *, projects: list[str] | None = None) -> FastModelResult:
        prompt = _analysis_prompt(text, projects=projects)
        try:
            raw = self.transport(
                endpoint=self.endpoint,
                model=self.model,
                prompt=prompt,
                timeout_seconds=self.timeout_seconds,
            )
            result = parse_fast_model_json(raw)
            if result.confidence < self.min_confidence:
                raise ValueError(f"fast model confidence {result.confidence:.2f} below threshold {self.min_confidence:.2f}")
            result = self._apply_direct_response_policy(result, text)
            result = self._ensure_ack_text(result, text)
            self.last_error = None
            return result
        except Exception as exc:
            self.last_error = str(exc)
            return self.fallback.analyze_input(text, projects=projects)

    def summarize(self, text: str) -> SummaryResult:
        prompt = _summary_prompt(text, summary_max_chars=self.summary_max_chars)
        try:
            raw = self.transport(
                endpoint=self.endpoint,
                model=self.model,
                prompt=prompt,
                timeout_seconds=self.timeout_seconds,
            )
            result = parse_summary_json(raw, source_text=text, summary_max_chars=self.summary_max_chars)
            self.last_error = None
            return result
        except Exception as exc:
            self.last_error = str(exc)
            return self.fallback.summarize(text)

    def explain_error(self, text: str) -> ErrorExplanationResult:
        prompt = _error_explanation_prompt(text)
        try:
            raw = self.transport(
                endpoint=self.endpoint,
                model=self.model,
                prompt=prompt,
                timeout_seconds=self.timeout_seconds,
            )
            result = parse_error_explanation_json(raw, source_text=text)
            self.last_error = None
            return result
        except Exception as exc:
            self.last_error = str(exc)
            return self.fallback.explain_error(text)

    def _apply_direct_response_policy(self, result: FastModelResult, text: str) -> FastModelResult:
        if not result.direct_response_text:
            return result
        if (
            result.confidence < self.direct_response_min_confidence
            or not is_safe_direct_response_for_request(text, result.direct_response_kind, result.direct_response_text)
        ):
            return replace(result, direct_response_text=None, direct_response_kind=None, ack=True, ack_text=None)
        return replace(result, ack=False, ack_text=None)

    def _ensure_ack_text(self, result: FastModelResult, text: str) -> FastModelResult:
        if result.direct_response_text:
            return replace(result, ack=False, ack_text=None)
        if not result.ack and str(text or "").strip():
            result = replace(result, ack=True)
        if not result.ack:
            return result
        ack_text = natural_ack_for(text)
        return replace(result, ack_text=sanitize_ack_text(ack_text))


def build_fast_model(extra: dict[str, Any] | None = None):
    extra = dict(extra or {})
    provider = str(os.getenv("LOGOS_FAST_MODEL_PROVIDER") or extra.get("fast_model_provider") or "deterministic").strip().lower()
    summary_max_chars = int(os.getenv("LOGOS_SUMMARY_MAX_CHARS") or extra.get("summary_max_chars") or 240)
    fallback = DeterministicFastModel(summary_max_chars=summary_max_chars)
    if provider in {"", "deterministic", "stub", "test"}:
        return fallback
    if provider in {"ollama", "local", "auto"}:
        return OllamaFastModel(
            endpoint=_optional_text(os.getenv("LOGOS_FAST_MODEL_ENDPOINT") or extra.get("fast_model_endpoint")),
            model=_optional_text(os.getenv("LOGOS_FAST_MODEL_MODEL") or extra.get("fast_model_model")),
            timeout_seconds=float(os.getenv("LOGOS_FAST_MODEL_TIMEOUT") or extra.get("fast_model_timeout", 2.5)),
            min_confidence=float(os.getenv("LOGOS_FAST_MODEL_MIN_CONFIDENCE") or extra.get("fast_model_min_confidence", 0.55)),
            direct_response_min_confidence=float(
                os.getenv("LOGOS_FAST_DIRECT_RESPONSE_MIN_CONFIDENCE")
                or extra.get("fast_direct_response_min_confidence", 0.86)
            ),
            summary_max_chars=summary_max_chars,
            transport=extra.get("fast_model_transport"),
            fallback=fallback,
        )
    return fallback


def ollama_generate(*, endpoint: str, model: str, prompt: str, timeout_seconds: float) -> str:
    payload = json.dumps(
        {
            "model": model,
            "prompt": prompt,
            "stream": False,
            "format": "json",
            "options": {"temperature": 0.0, "num_predict": 256},
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        f"{endpoint.rstrip('/')}/api/generate",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            body = response.read().decode("utf-8")
    except (urllib.error.URLError, TimeoutError) as exc:
        raise RuntimeError(f"ollama request failed: {exc}") from exc
    try:
        outer = json.loads(body)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"ollama response was not JSON: {exc.msg}") from exc
    generated = outer.get("response") if isinstance(outer, dict) else None
    if not isinstance(generated, str) or not generated.strip():
        raise RuntimeError("ollama response did not include generated text")
    return generated


def _analysis_prompt(text: str, *, projects: list[str] | None = None) -> str:
    projects_text = ", ".join(projects or []) or "none"
    return (
        "You are Logos' fast local control and micro-response model. Return only strict JSON with these keys: "
        "ack(boolean), ack_text(string|null), direct_response_text(string|null), direct_response_kind(social|app_help|simple_text|null), "
        "switch_intent(object|null), create_intent(object|null), resume_intent(object|null), cancel_intent(boolean), "
        "approval_decision(approve|deny|null), confidence(number 0..1). "
        "Only emit control intents for explicit, low-ambiguity user requests. Do not invent project names. "
        "Direct-response only for these exact narrow request classes: greetings, thanks, are-you-there checks, static Logos app help, how to stop/cancel a run, or “say hello”. "
        "For every other request, including facts, math, coding, project state, control actions, approvals, denials, switching, resuming, files, logs, memory, or current information, set direct_response_text=null and provide a short natural ack. "
        "Avoid generic ack_text such as Got it, Sure, or Okay when a contextual ack fits. "
        "Never combine direct_response_text with a control or approval intent. "
        "switch_intent shape: {\"project_title\":\"...\"}; create_intent: {\"title\":\"...\"}; resume_intent: {\"target\":\"...\"}. "
        f"Known projects: {projects_text}. User text: {json.dumps(str(text or ''))}"
    )


def _summary_prompt(text: str, *, summary_max_chars: int) -> str:
    return (
        "Summarize this Hermes assistant response for notification metadata and compact surfaces. Return only strict JSON: "
        "{\"summary_text\":\"...\"}. One sentence, no secrets, no markdown, "
        f"maximum {summary_max_chars} characters. Text: {json.dumps(str(text or ''))}"
    )


def _error_explanation_prompt(text: str) -> str:
    return (
        "Rewrite this raw Hermes/provider failure into one short, user-facing final message. "
        "Return only strict JSON: {\"message_text\":\"...\"}. Explain that Hermes could not complete the request, "
        "include the useful provider error in plain language, suggest retrying or switching models if it repeats, "
        "and do not include secrets, stack traces, markdown, or blame. Raw error: "
        f"{json.dumps(str(text or ''))}"
    )


def _extract_json_object(raw: str) -> str:
    text = str(raw or "").strip()
    if text.startswith("{") and text.endswith("}"):
        return text
    start = text.find("{")
    end = text.rfind("}")
    if start >= 0 and end > start:
        return text[start : end + 1]
    return text


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


def _optional_text(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None
