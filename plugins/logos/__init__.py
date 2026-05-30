"""Logos Hermes platform plugin package.

The platform adapter depends on the Hermes ``gateway`` package. The utility
modules in this package (``schema``, ``store``, ``pairing``, ``crypto``, ...)
do not, so the adapter import is guarded to keep those modules importable on
their own — for example in CI that runs the Hermes-free unit tests without a
Hermes checkout. In a real Hermes deployment the gateway is always present, so
``LogosAdapter`` and ``register`` import exactly as before.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from typing import Any

try:
    from .adapter import LogosAdapter, register
except ImportError as exc:  # pragma: no cover - only hit when Hermes is absent
    _ADAPTER_IMPORT_ERROR = exc

    # Hermes-absent fallback: rebind the imported class name to None so the package stays
    # importable for the Hermes-free unit tests. Assigning None to a name mypy knows as a type
    # is the intent here, at the gateway-import boundary.
    LogosAdapter = None  # type: ignore[assignment,misc]

    def register(ctx: Any) -> None:
        raise RuntimeError(
            "Logos platform registration requires the Hermes gateway package, "
            f"which could not be imported: {_ADAPTER_IMPORT_ERROR}"
        )


__all__ = ["LogosAdapter", "register"]
