from __future__ import annotations

import inspect
import logging
from typing import Any

from .apns import PrivateNotificationKind, build_private_apns_payload

logger = logging.getLogger(__name__)

# APNS reasons that mean a device token is permanently invalid and should be dropped.
APNS_STALE_DEVICE_REASONS = {"BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"}


class PrivateNotifier:
    """Sends content-free APNS wake signals and cleans up stale device tokens.

    Extracted from adapter.py. The payload deliberately omits response text, commands, and
    secrets (see build_private_apns_payload); it only tells the app that Logos needs attention.
    """

    async def send(
        self,
        store: Any,
        apns: Any,
        kind: PrivateNotificationKind,
        *,
        project_key: str,
        session_id: str | None = None,
        message_id: str | None = None,
        server_seq: int | None = None,
        request_id: str | None = None,
        sensitive_context: dict[str, Any] | None = None,
    ) -> None:
        payload = build_private_apns_payload(
            kind,
            project_key=project_key,
            session_id=session_id,
            message_id=message_id,
            server_seq=server_seq,
            request_id=request_id,
            sensitive_context=sensitive_context,
        )
        for device in store.list_devices(active_only=True):
            if not device.apns_token:
                continue
            if "notifications" not in {str(item).lower() for item in device.capabilities}:
                continue
            environment = (
                str(device.apns_environment or apns.config.environment or "").strip().lower() or None
            )
            try:
                result_or_awaitable = apns.send(device.apns_token, payload, environment=environment)
                result = await result_or_awaitable if inspect.isawaitable(result_or_awaitable) else result_or_awaitable
            except Exception as exc:  # pragma: no cover - exercised with injected clients
                logger.warning(
                    "Logos APNS send raised for device_id=%s environment=%s error_type=%s",
                    device.device_id,
                    environment,
                    type(exc).__name__,
                )
                continue
            if not result.success and not result.skipped:
                reason = str(result.reason or "")
                if reason in APNS_STALE_DEVICE_REASONS or result.status == 410:
                    store.clear_device_apns_registration(device.device_id)
                logger.warning(
                    "Logos APNS send failed for device_id=%s environment=%s status=%s reason=%s apns_id=%s temporary=%s",
                    device.device_id,
                    result.environment or environment,
                    result.status,
                    result.reason,
                    result.apns_id,
                    result.temporary_failure,
                )
