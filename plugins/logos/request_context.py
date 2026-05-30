from __future__ import annotations

import contextlib
import contextvars
from collections.abc import Iterator

# Correlates background Logos processing (callbacks fired from Hermes' run task) back to the
# originating request/project/session, so mirrored messages and telemetry can be tagged without
# threading IDs through every call. Extracted from adapter.py.
_CURRENT_LOGOS_REQUEST_CONTEXT: contextvars.ContextVar[dict[str, str] | None] = (
    contextvars.ContextVar(
        "logos_request_context",
        default=None,
    )
)


def current_request_context() -> dict[str, str] | None:
    """Return the request context for the currently-executing Logos message, if any."""
    return _CURRENT_LOGOS_REQUEST_CONTEXT.get()


@contextlib.contextmanager
def request_scope(context: dict[str, str] | None) -> Iterator[None]:
    """Bind ``context`` for the duration of the block (including awaits in the same task)."""
    token = _CURRENT_LOGOS_REQUEST_CONTEXT.set(context)
    try:
        yield
    finally:
        _CURRENT_LOGOS_REQUEST_CONTEXT.reset(token)
