# QR Pairing Authorizes Logos Device Implementation Plan

> **For Hermes:** Use plugin-only changes. Do not modify Hermes core.

**Goal:** Make a successful Logos QR scan enough to let the paired iPhone send messages through the Hermes gateway without receiving the generic `hermes pairing approve logos <code>` prompt.

**Architecture:** Keep the Hermes core authorization path intact. Bridge Logos' adapter-owned QR pairing state into Hermes' existing gateway pairing store from the Logos plugin, so `_is_user_authorized()` sees the QR-paired device ID as an approved `logos` user. Also ensure already-paired/authenticated devices are approved just before gateway dispatch, covering devices paired before this fix.

**Tech Stack:** Python plugin code under `plugins/logos/`, pytest tests under `tests/`, existing Hermes `gateway.pairing.PairingStore` API.

---

## Feasibility

Possible without Hermes core edits.

The core gateway already checks `PairingStore.is_approved(platform, user_id)` for every platform, including plugin platforms. The Logos plugin can write an approved `logos` user entry for the QR-paired `device_id`. That preserves Hermes' normal authorization gate while eliminating the second pairing prompt.

## Task 1: Add regression test

**Objective:** Prove a QR-paired/authenticated Logos device is approved in Hermes' generic gateway pairing store before dispatch.

**Files:**
- Modify: `tests/test_logos_pairing.py`

**Steps:**
1. Patch `gateway.pairing.PAIRING_DIR` to a temp directory.
2. Create a `CapturingLogosAdapter` with temp Logos DB.
3. Seed the Logos store with a registered `iphone` device, simulating a completed QR pairing.
4. Send a final `text_input` envelope from `iphone`.
5. Assert the captured gateway event is produced.
6. Assert `PairingStore().is_approved("logos", "iphone")` is true.
7. Run the new test and verify RED.

## Task 2: Implement plugin-only bridge

**Objective:** Approve QR-paired Logos devices in Hermes gateway pairing state without changing Hermes core.

**Files:**
- Modify: `plugins/logos/adapter.py`

**Steps:**
1. Add a private helper on `LogosAdapter`, e.g. `_approve_gateway_pairing_for_device(device_id, display_name=None)`.
2. The helper must:
   - normalize blank device IDs away;
   - require `is_device_allowed(device_id)` before approving;
   - import `gateway.pairing.PairingStore` lazily;
   - avoid logging or exposing secrets;
   - no-op safely if the gateway pairing import/store fails.
3. Use `PairingStore.is_approved("logos", device_id)` to avoid unnecessary writes.
4. Use the store's existing lock and approval write path to add the device as an approved `logos` user.
5. Call the helper after `handle_pairing_envelope()` upserts the QR-paired device.
6. Call the helper in `_handle_register_device()` after the device is upserted.
7. Call the helper in `_dispatch_gateway_text()` before `handle_message(event)` so devices paired before this patch are bridged on their next authenticated dispatch.

## Task 3: Verify

**Commands:**

```bash
python -m pytest tests/test_logos_pairing.py::test_qr_paired_device_is_gateway_authorized_before_dispatch -q
python -m pytest tests/test_logos_pairing.py tests/test_stage_e_interactions.py tests/test_stage_d_adapter_projects.py -q
```

**Expected:** all selected tests pass.

## Task 4: Safety checks

**Checks:**
- No files under `/Users/ryan/.hermes/hermes-agent` modified.
- No device secrets, QR tokens, or connection strings printed into test output or final report.
- Existing devices paired before this fix are covered by the dispatch/register path.
