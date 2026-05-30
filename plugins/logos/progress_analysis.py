from __future__ import annotations

import re

# Gateway-status / tool-progress / terminal-error text detection, extracted from adapter.py.
# Pure regex + string logic (no Hermes/adapter dependency).

GATEWAY_STILL_WORKING_RE = re.compile(
    r"^\s*(?:⏳\s*)?Still working(?:\.\.\.|…)(?:\s*\(|\s|$)", re.IGNORECASE
)
# Hermes' long-run heartbeat. Two observed phrasings:
#   "⏳ Still working... (3 min elapsed — iteration 1/1000, API call #1 completed)"
#   "⏳ Working — 3 min — iteration 2/1000, API call #2 completed"
# The first also matches GATEWAY_STILL_WORKING_RE; the second ("Working —", no "...") does
# not, so it would otherwise fall through to a final assistant bubble. The "iteration N/M"
# token keeps this anchored to heartbeats and off ordinary replies.
GATEWAY_WORKING_HEARTBEAT_RE = re.compile(
    r"^\s*(?:⏳\s*)?(?:Still\s+)?Working\b.*?\biteration\s+\d+\s*/\s*\d+\b", re.IGNORECASE
)
GATEWAY_RETRY_STATUS_RE = re.compile(
    r"^\s*(?:⏳\s*)?Retrying\s+in\s+.+?\battempt\s+\d+/\d+\b", re.IGNORECASE
)
GATEWAY_NON_RETRYABLE_STATUS_RE = re.compile(
    r"^\s*(?:⚠️?|⚠\ufe0f?|❌)?\s*Non-retryable error\s+\(HTTP\s+[^)]*\)"
    r"(?:\s*[—-]\s*trying fallback(?:\.\.\.|…)?|:\s+.+)\s*$",
    re.IGNORECASE,
)
GATEWAY_PROVIDER_STATUS_RE = re.compile(
    r"^\s*(?:⚠️?|⚠\ufe0f?)?\s*No response from provider for\s+.*?\bAborting call\.?\s*$",
    re.IGNORECASE,
)
GATEWAY_CONTEXT_STATUS_RE = re.compile(
    r"^\s*(?:⏳\s*)?(?:"
    r"(?:preflight\s+compression|context\s+(?:compaction|compression))\s*[:\-–—]\s*(?:"  # noqa: RUF001
    r"(?:started|starting|running|complete|completed|in progress)(?:\.\.\.|[.!…])?\s*$"
    r"|(?:compact(?:ing)?|compress(?:ing)?)\s+context(?:\s*(?:\.\.\.|…)|\s+(?:before\s+continuing|to\s+continue|for\s+continuation|now|started|starting|running|complete|completed|in\s+progress)(?:\.\.\.|[.!…])?)\s*$"
    r"|context(?:\.\.\.|[.!…])?\s*$"
    r")"
    r"|(?:compact|compacting|compressing)\s+context(?:\s*(?:\.\.\.|…)|\s+(?:before\s+continuing|to\s+continue|for\s+continuation|now|started|starting|running|complete|completed|in\s+progress)(?:\.\.\.|[.!…])?|\s*)$"
    r")",
    re.IGNORECASE,
)
GATEWAY_LIFECYCLE_STATUS_RE = re.compile(
    r"^\s*(?:⚠️?|⚠\ufe0f?)?\s*Gateway\s+(?:restarting|shutting down)\b", re.IGNORECASE
)
RAW_TERMINAL_ERROR_RE = re.compile(
    r"^\s*(?:⚠️?|⚠\ufe0f?|❌)?\s*(?:"
    r"'[^']+'\s+object\s+(?:is\s+not\s+\w+|has\s+no\s+attribute\s+'[^']+')"
    r"|(?:[A-Za-z_][A-Za-z0-9_.]*Error|Exception|TimeoutError|RuntimeError|TypeError|ValueError):\s+.+"
    r")\s*$",
    re.IGNORECASE,
)
PROGRESS_TOOL_NAMES = {
    "airtable",
    "browser_click",
    "browser_navigate",
    "browser_scroll",
    "browser_snapshot",
    "browser_type",
    "browser_vision",
    "clarify",
    "computer_use",
    "cronjob",
    "delegate_task",
    "execute_code",
    "ha_call_service",
    "ha_get_state",
    "ha_list_entities",
    "ha_list_services",
    "image_generate",
    "memory",
    "patch",
    "process",
    "read_file",
    "search_files",
    "send_message",
    "skill_manage",
    "skill_view",
    "skills_list",
    "terminal",
    "text_to_speech",
    "todo",
    "vision_analyze",
    "web_extract",
    "web_search",
    "write_file",
}
PROGRESS_LINE_RE = re.compile(r"^\W+\s+(?P<tool>[A-Za-z_][A-Za-z0-9_.-]*)(?:\(|:|…|\.\.\.|\s|$)")


class ProgressAnalyzer:
    """Classify gateway-status / tool-progress / terminal-error text. Stateless and pure."""

    @staticmethod
    def _looks_like_tool_progress_text(content: str) -> bool:
        lines = [line.strip() for line in str(content or "").splitlines() if line.strip()]
        if not lines:
            return False
        for line in lines:
            match = PROGRESS_LINE_RE.match(line)
            if not match:
                return False
            tool = match.group("tool").strip(" .:()[]{}")
            if tool not in PROGRESS_TOOL_NAMES and "_" not in tool and "." not in tool:
                return False
        return True

    @staticmethod
    def _looks_like_gateway_status_text(content: str) -> bool:
        text = str(content or "").strip()
        if not text:
            return False
        return bool(
            GATEWAY_STILL_WORKING_RE.match(text)
            or GATEWAY_WORKING_HEARTBEAT_RE.match(text)
            or GATEWAY_RETRY_STATUS_RE.match(text)
            or GATEWAY_NON_RETRYABLE_STATUS_RE.match(text)
            or GATEWAY_PROVIDER_STATUS_RE.match(text)
            or GATEWAY_CONTEXT_STATUS_RE.search(text)
            or GATEWAY_LIFECYCLE_STATUS_RE.match(text)
        )

    @staticmethod
    def _gateway_lifecycle_interruption_reason(content: str) -> str | None:
        text = str(content or "").strip().lower()
        if not GATEWAY_LIFECYCLE_STATUS_RE.match(text):
            return None
        if "restarting" in text:
            return "gateway_restarting"
        if "shutting down" in text:
            return "gateway_shutting_down"
        return "gateway_interrupted"

    @staticmethod
    def _looks_like_terminal_error_text(content: str) -> bool:
        text = str(content or "").strip()
        if not text:
            return False
        if GATEWAY_NON_RETRYABLE_STATUS_RE.match(text):
            return False
        return bool(RAW_TERMINAL_ERROR_RE.match(text))

    def _progress_kind_for_text(self, content: str) -> str | None:
        if self._looks_like_tool_progress_text(content):
            return "tool_progress"
        if self._looks_like_gateway_status_text(content):
            return "gateway_status"
        return None
