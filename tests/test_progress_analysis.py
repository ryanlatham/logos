"""Hermes-free unit tests for the gateway-status / tool-progress text classifier.

These cover `ProgressAnalyzer` directly (it imports no gateway code), so they run in
the Tier-1 CI lane — where the adapter-level tests in `test_stage_b_adapter_ws.py`
are skipped. The classifier decides whether Hermes status text is folded into the
progress/"working" card (transient) or delivered as a final assistant message bubble.
"""

import pytest

from logos.progress_analysis import ProgressAnalyzer

analyzer = ProgressAnalyzer()

# Heartbeat / status strings that must be treated as transient gateway status.
GATEWAY_STATUS_TEXTS = [
    # Canonical long-run heartbeat.
    "⏳ Still working... (3 min elapsed — iteration 1/1000, API call #1 completed)",
    # Newer heartbeat phrasing ("Working —", no "Still", no "..."): the regression that
    # otherwise rendered as a message bubble + audio instead of in the working window.
    "⏳ Working — 3 min — iteration 2/1000, API call #2 completed",
    # Same newer phrasing without the leading hourglass glyph.
    "Working — 12 sec — iteration 7/40, API call #7 completed",
    # Retry + context-compaction families (already covered; guard against regressions).
    "⏳ Retrying in 2.6s (attempt 1/3)...",
    "⏳ context compaction: started",
]

# Ordinary assistant replies that must NOT be misclassified as status.
FINAL_MESSAGE_TEXTS = [
    "The next Super Bowl is Super Bowl LXI, on Sunday, February 14, 2027.",
    "08:14:33 PDT on Saturday, May 30, 2026.",
    "Working on the quarterly report now.",
    "Here are 3 ideas: iteration is key, we are 2/3 done.",
]


@pytest.mark.parametrize("text", GATEWAY_STATUS_TEXTS)
def test_gateway_status_text_classified_as_progress(text):
    assert analyzer._looks_like_gateway_status_text(text) is True
    assert analyzer._progress_kind_for_text(text) == "gateway_status"


@pytest.mark.parametrize("text", FINAL_MESSAGE_TEXTS)
def test_ordinary_replies_are_not_progress(text):
    assert analyzer._looks_like_gateway_status_text(text) is False
    assert analyzer._progress_kind_for_text(text) is None


def test_working_heartbeat_does_not_trigger_lifecycle_interruption():
    # A heartbeat must not be mistaken for a gateway restart/shutdown (which would
    # flip the run to idle/interrupted).
    text = "⏳ Working — 3 min — iteration 2/1000, API call #2 completed"
    assert analyzer._gateway_lifecycle_interruption_reason(text) is None
