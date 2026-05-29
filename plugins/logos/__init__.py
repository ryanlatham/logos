"""Logos Hermes platform plugin package.

The platform adapter depends on the Hermes ``gateway`` package. The utility
modules in this package (``schema``, ``store``, ``pairing``, ``crypto``, ...)
do not, so the adapter import is guarded to keep those modules importable on
their own — for example in CI that runs the Hermes-free unit tests without a
Hermes checkout. In a real Hermes deployment the gateway is always present, so
``LogosAdapter`` and ``register`` import exactly as before.
"""

try:
    from .adapter import LogosAdapter, register
except ImportError as exc:  # pragma: no cover - only hit when Hermes is absent
    _ADAPTER_IMPORT_ERROR = exc

    LogosAdapter = None  # type: ignore[assignment]

    def register(ctx):  # type: ignore[misc]
        raise RuntimeError(
            "Logos platform registration requires the Hermes gateway package, "
            f"which could not be imported: {_ADAPTER_IMPORT_ERROR}"
        )

__all__ = ["LogosAdapter", "register"]
