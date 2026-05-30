#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import hashlib
import hmac
import json
import os
import time
import uuid


def frame(
    msg_type: str,
    *,
    request_id: str | None = None,
    device_id: str,
    project_key: str | None = None,
    payload: dict | None = None,
) -> str:
    data = {
        "type": msg_type,
        "request_id": request_id or str(uuid.uuid4()),
        "device_id": device_id,
        "payload": payload or {},
    }
    if project_key:
        data["project_key"] = project_key
    return json.dumps(data)


def hello_payload(
    secret: str, *, device_id: str, request_id: str, project_key: str | None
) -> dict[str, str | int]:
    timestamp_ms = int(time.time() * 1000)
    nonce = str(uuid.uuid4())
    message = "\n".join(
        ["logos-v1", device_id, request_id, project_key or "", str(timestamp_ms), nonce]
    )
    signature = hmac.new(
        secret.encode("utf-8"), message.encode("utf-8"), hashlib.sha256
    ).hexdigest()
    return {"timestamp_ms": timestamp_ms, "nonce": nonce, "signature": signature}


async def main() -> int:
    parser = argparse.ArgumentParser(description="Minimal Logos WebSocket test client")
    parser.add_argument("message", nargs="?", default="/status", help="Text to send through Logos")
    parser.add_argument("--url", default=os.getenv("LOGOS_WS_URL", "ws://127.0.0.1:8765"))
    parser.add_argument(
        "--secret",
        default=os.getenv("LOGOS_DEVICE_SECRET"),
        help="Shared secret (or LOGOS_DEVICE_SECRET)",
    )
    parser.add_argument("--device-id", default=os.getenv("LOGOS_DEVICE_ID", "logos-cli"))
    parser.add_argument("--project-key", default="default")
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()

    if not args.secret:
        parser.error("--secret or LOGOS_DEVICE_SECRET is required")

    import websockets

    async with websockets.connect(args.url) as ws:
        await ws.send(
            frame(
                "hello",
                request_id="hello-1",
                device_id=args.device_id,
                project_key=args.project_key,
                payload=hello_payload(
                    args.secret,
                    device_id=args.device_id,
                    request_id="hello-1",
                    project_key=args.project_key,
                ),
            )
        )
        print(await asyncio.wait_for(ws.recv(), timeout=args.timeout))
        await ws.send(
            frame(
                "text_input",
                request_id="text-1",
                device_id=args.device_id,
                project_key=args.project_key,
                payload={
                    "text": args.message,
                    "is_final": True,
                    "client_msg_id": str(uuid.uuid4()),
                },
            )
        )
        while True:
            print(await asyncio.wait_for(ws.recv(), timeout=args.timeout))


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
