#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import os
import signal
from pathlib import Path

from gateway.config import PlatformConfig
from gateway.platforms.base import MessageEvent
from logos.adapter import LogosAdapter


class StageFMockLogosAdapter(LogosAdapter):
    """Small Hermes-like adapter for iOS Simulator UI validation.

    It uses the real Logos WebSocket/protocol/storage code and replaces only the
    Hermes gateway run with a deterministic echo. This is not product behavior;
    it is a Stage F simulator fixture.
    """

    async def handle_message(self, event: MessageEvent) -> None:  # type: ignore[override]
        content = event.text.strip()
        chat_id = event.source.chat_id if event.source else "project:default"
        if content == "/mock_approval":
            await self.send_exec_approval(
                chat_id=chat_id,
                command="echo stage-f",
                session_key="stage-f-session",
                description="Stage F fixture approval",
                metadata={"approval_id": "stage-f-approval", "risk": "Fixture only; no command is executed."},
            )
            return
        if content == "/mock_clarify":
            await self.send_clarify(
                chat_id=chat_id,
                clarify_id="stage-f-clarify",
                question="Which Stage F path should Logos test?",
                choices=["text", "approval", "clarification"],
                session_key="stage-f-session",
            )
            return
        await self.send(
            chat_id=chat_id,
            content=f"Mock Hermes received: {content}",
            metadata={"source": "stage_f_mock"},
        )


async def amain() -> int:
    parser = argparse.ArgumentParser(description="Run a Stage F Logos mock adapter for iOS Simulator validation")
    parser.add_argument("--host", default=os.getenv("LOGOS_WS_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.getenv("LOGOS_WS_PORT", "8765")))
    parser.add_argument("--secret", default=os.getenv("LOGOS_DEVICE_SECRET", "stage-f-secret"))
    parser.add_argument("--store", default=os.getenv("LOGOS_STORE_PATH", "/tmp/logos-stage-f-simulator.db"))
    args = parser.parse_args()

    store = Path(args.store)
    if store.exists():
        store.unlink()
    os.environ["LOGOS_DEVICE_SECRET"] = args.secret
    os.environ.setdefault("LOGOS_ALLOW_ALL_USERS", "1")
    adapter = StageFMockLogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={
                "host": args.host,
                "port": args.port,
                "store_path": str(store),
            },
        )
    )
    await adapter.connect()
    print(f"READY ws://{args.host}:{adapter.ws_server.actual_port} secret=[REDACTED] store={store}", flush=True)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            pass
    await stop.wait()
    await adapter.disconnect()
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(amain()))
