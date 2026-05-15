from __future__ import annotations

import subprocess
from pathlib import Path


def test_cli_help_does_not_import_websocket_dependency_before_argparse_help():
    root = Path(__file__).resolve().parents[1]

    result = subprocess.run(
        ["/usr/bin/python3", str(root / "scripts" / "logos_ws_client.py"), "--help"],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
    )

    assert result.returncode == 0
    assert "Minimal Logos WebSocket test client" in result.stdout
