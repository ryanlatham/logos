from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HERMES_ROOT = Path('/Users/ryan/.hermes/hermes-agent')

for path in (ROOT / 'plugins', HERMES_ROOT):
    value = str(path)
    if value not in sys.path:
        sys.path.insert(0, value)

os.environ.setdefault('LOGOS_DEVICE_SECRET', 'dev-secret')
os.environ.setdefault('LOGOS_ALLOW_ALL_USERS', '1')
