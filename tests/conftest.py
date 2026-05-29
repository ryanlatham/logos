from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
HERMES_ROOT = Path(os.environ.get('HERMES_SRC', Path.home() / '.hermes' / 'hermes-agent'))

for path in (ROOT / 'plugins', HERMES_ROOT):
    value = str(path)
    if value not in sys.path:
        sys.path.insert(0, value)

os.environ.setdefault('LOGOS_DEVICE_SECRET', 'dev-secret')
os.environ.setdefault('LOGOS_ALLOW_ALL_USERS', '1')


def _hermes_available() -> bool:
    """Whether the external Hermes ``gateway`` package can be imported.

    CI Tier 1 runs without a Hermes checkout, so the Hermes-dependent modules
    listed below are not collected there; the Hermes-free tests (schema, store,
    protocol, CLI, crypto) still run. Tier 2 and local dev set ``HERMES_SRC``
    and exercise the full suite.
    """
    try:
        import gateway.config  # noqa: F401
        import gateway.pairing  # noqa: F401
    except Exception:
        return False
    return True


HERMES_AVAILABLE = _hermes_available()

# Test modules that import ``gateway.*`` at load time (directly, or transitively
# via ``logos.adapter``). Without Hermes they cannot be collected, so skip them
# rather than erroring. Keep this list in sync when adding adapter-level tests;
# a forgotten entry fails loudly in Tier-1 CI rather than passing silently.
_HERMES_DEPENDENT_MODULES = [
    "test_stage_b_plugin_registration.py",
    "test_stage_b_adapter_ws.py",
    "test_stage_c_adapter_replay.py",
    "test_stage_d_adapter_projects.py",
    "test_stage_e_interactions.py",
    "test_stage_f_mock_adapter.py",
    "test_stage_g_tts.py",
    "test_stage_h_fast_model.py",
    "test_stage_j_notifications.py",
    "test_stage_l_commands.py",
    "test_logos_pairing.py",
    "test_review_hardening.py",
]

if not HERMES_AVAILABLE:
    collect_ignore = list(_HERMES_DEPENDENT_MODULES)


@pytest.fixture(autouse=True)
def isolate_gateway_pairing_store(tmp_path, monkeypatch):
    if not HERMES_AVAILABLE:
        # Hermes-free run: the gateway-dependent modules above are not collected,
        # so this autouse fixture simply no-ops for the remaining tests.
        return
    import gateway.pairing as gateway_pairing

    monkeypatch.setattr(gateway_pairing, 'PAIRING_DIR', tmp_path / 'gateway-pairing')
