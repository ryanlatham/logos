from __future__ import annotations

import logging
import uuid
from typing import TYPE_CHECKING, Any

from .schema import Envelope, error_frame

if TYPE_CHECKING:
    from ._adapter_core import LogosAdapterCore

    _MixinBase = LogosAdapterCore
else:
    _MixinBase = object

logger = logging.getLogger(__name__)


class AudioMixin(_MixinBase):
    """playback_audio frame handling + TTS audio streaming (from adapter.py).

    Mixed into LogosAdapter; uses self.{store, ws_server, tts, _project_key_for,
    _is_short_final_audio_text, _summary_for_message, _stream_tts_audio}.
    """

    async def _handle_playback_audio(self, envelope: Envelope) -> dict[str, Any] | None:
        project_key = self._project_key_for(envelope)
        payload = envelope.payload
        session_id = str(
            envelope.session_id or payload.get("session_id") or f"project:{project_key}"
        )
        message_id = payload.get("message_id")
        requested_mode = str(payload.get("mode") or "summary").strip().lower() or "summary"
        selected_mode = requested_mode
        selection_reason = f"requested_{requested_mode}"
        text = None
        if message_id:
            message = self.store.get_message(session_id, str(message_id))
            if message is None:
                return error_frame(
                    "message_not_found",
                    f"no Logos message found for {session_id}/{message_id}",
                    request_id=envelope.request_id,
                    device_id=envelope.device_id,
                    project_key=project_key,
                )
            if message.project_key != project_key:
                return error_frame(
                    "message_project_mismatch",
                    "playback_audio message does not belong to the requested project",
                    request_id=envelope.request_id,
                    device_id=envelope.device_id,
                    project_key=project_key,
                )
            if requested_mode == "final_auto":
                if self._is_short_final_audio_text(message.content):
                    selected_mode = "full"
                    selection_reason = "short_final_full"
                    text = message.content
                else:
                    summary, summary_status = self._summary_for_message(message)
                    selected_mode = "summary"
                    selection_reason = f"long_final_summary_{summary_status}"
                    text = summary.summary_text
            elif requested_mode == "summary":
                summary, summary_status = self._summary_for_message(message)
                selected_mode = "summary"
                selection_reason = f"requested_summary_{summary_status}"
                text = summary.summary_text
            else:
                selected_mode = requested_mode
                selection_reason = (
                    "requested_full" if requested_mode == "full" else f"requested_{requested_mode}"
                )
                text = message.content
        else:
            text = payload.get("text") or payload.get("summary_text")
            if requested_mode == "final_auto":
                selected_mode = "full"
                selection_reason = "payload_text_full"
        if not isinstance(text, str) or not text.strip():
            return error_frame(
                "missing_audio_source",
                "playback_audio requires payload.text or payload.message_id",
                request_id=envelope.request_id,
                device_id=envelope.device_id,
                project_key=project_key,
            )
        audio_id = str(payload.get("audio_id") or f"audio-{uuid.uuid4()}")
        return await self._stream_tts_audio(
            text=text,
            audio_id=audio_id,
            project_key=project_key,
            session_id=session_id,
            request_id=envelope.request_id,
            device_id=envelope.device_id,
            message_id=str(message_id) if message_id else None,
            mode=selected_mode,
            requested_mode=requested_mode,
            selection_reason=selection_reason,
            source=getattr(self.tts, "source_name", "tts"),
        )

    async def _stream_tts_audio(
        self,
        *,
        text: str,
        audio_id: str,
        project_key: str,
        session_id: str,
        request_id: str | None,
        device_id: str | None,
        message_id: str | None,
        mode: str,
        source: str,
        requested_mode: str | None = None,
        selection_reason: str | None = None,
    ) -> dict[str, Any] | None:
        requested_mode = requested_mode or mode
        selection_reason = selection_reason or f"requested_{requested_mode}"
        try:
            chunks = self.tts.iter_chunks(text=text, audio_id=audio_id)
        except Exception as exc:
            error_type = exc.__class__.__name__
            logger.warning(
                "Logos TTS failed for audio_id=%s provider=%s error_type=%s",
                audio_id,
                source,
                error_type,
            )
            return error_frame(
                "tts_failed",
                f"TTS failed for provider {source} ({error_type})",
                request_id=request_id,
                device_id=device_id,
                project_key=project_key,
            )
        if not chunks:
            return error_frame(
                "tts_empty_audio",
                "TTS produced no audio chunks",
                request_id=request_id,
                device_id=device_id,
                project_key=project_key,
            )
        for chunk in chunks:
            frame = {
                "type": "audio_chunk",
                "request_id": request_id,
                "device_id": device_id,
                "project_key": project_key,
                "session_id": session_id,
                "server_seq": self.store.next_server_seq(),
                "payload": {
                    "audio_id": audio_id,
                    "message_id": message_id,
                    "chunk_index": chunk.index,
                    "mime_type": chunk.mime_type,
                    "encoding": chunk.encoding,
                    "mode": mode,
                    "requested_mode": requested_mode,
                    "selection_reason": selection_reason,
                    "data": chunk.data_b64,
                },
            }
            if self.ws_server is not None:
                await self.ws_server.broadcast(frame, project_key=project_key)
        end_frame = {
            "type": "audio_end",
            "request_id": request_id,
            "device_id": device_id,
            "project_key": project_key,
            "session_id": session_id,
            "server_seq": self.store.next_server_seq(),
            "payload": {
                "audio_id": audio_id,
                "message_id": message_id,
                "chunk_count": len(chunks),
                "mime_type": chunks[0].mime_type,
                "mode": mode,
                "requested_mode": requested_mode,
                "selection_reason": selection_reason,
                "source": source,
            },
        }
        if self.ws_server is not None:
            await self.ws_server.broadcast(end_frame, project_key=project_key)
            return None
        return end_frame
