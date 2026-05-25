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


@pytest.fixture(autouse=True)
def isolate_gateway_pairing_store(tmp_path, monkeypatch):
    import gateway.pairing as gateway_pairing

    monkeypatch.setattr(gateway_pairing, 'PAIRING_DIR', tmp_path / 'gateway-pairing')
