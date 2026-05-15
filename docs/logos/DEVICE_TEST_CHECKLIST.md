# Logos Device Test Checklist

Last updated: 2026-05-15T06:28:32-07:00

This checklist tracks validation that cannot be completed by Xcode Simulator alone. For an interactive walkthrough with checkboxes, command copy buttons, and a fillable report form, open `docs/logos/LOGOS_PHYSICAL_DEVICE_TEST_GUIDE.html`. Stage I establishes the voice path gates and Stage J adds APNS hardware/credential gates.

## Stage I — real iPhone ASR and speech state machine

Prerequisites:

- Install the Logos app on a physical iPhone signed with a real development team.
- Run the Logos adapter on the Mac with `LOGOS_DEVICE_SECRET` configured.
- Put the iPhone and Mac on the same trusted private network / Tailscale path.
- Configure the app adapter URL to the Mac tailnet address and port.

Validation steps:

1. Launch the app and verify the adapter connects.
2. Confirm iOS asks for Microphone and Speech Recognition permissions on first voice use.
3. Confirm voice controls stay disabled if on-device recognition is unavailable for the selected locale/device.
4. Confirm the app does **not** silently fall back to network speech recognition when local-only recognition is unavailable.
5. Hold-to-talk:
   - press and hold `Hold to Talk`,
   - speak a short request,
   - verify partial transcript text appears,
   - release,
   - verify exactly one final `speech` frame reaches Hermes and gets a response.
6. Hold-to-talk cancellation/error:
   - press with silence, then release,
   - verify no empty final turn is sent.
7. Tap-to-talk:
   - tap `Tap to Talk`,
   - speak a short request,
   - stop speaking,
   - verify energy/silence detection stops recording and sends the final transcript.
8. Tap-to-talk initial silence:
   - tap `Tap to Talk` and remain silent,
   - verify the app stops after the initial-silence timeout and sends no empty final turn.
9. Tap-to-talk manual stop:
   - tap `Tap to Talk`, speak, tap `Stop Tap`,
   - verify the final transcript dispatches once.
10. Fast repeated interactions:
    - rapidly tap voice controls,
    - verify only one recording session is active and the app does not crash.
11. Background interruption:
    - start voice, background the app or receive a call/system interruption if practical,
    - verify recording stops safely and no corrupt/empty turn is persisted.
12. Privacy spot check:
    - inspect adapter logs and verify full speech text is not logged unless explicit debug logging is enabled.

Record results in Stage K/L reports with device model, iOS version, locale, recognition availability, pass/fail notes, and any screenshots/logs.

## Stage J — real APNS and notification routing

Prerequisites:

- Apple Developer signing/provisioning configured for the Logos bundle id.
- Physical iPhone build installed from Xcode, not just Simulator.
- Adapter running with `LOGOS_DEVICE_SECRET` and APNS credentials:
  - `LOGOS_APNS_KEY_ID`
  - `LOGOS_APNS_TEAM_ID`
  - `LOGOS_APNS_BUNDLE_ID`
  - `LOGOS_APNS_AUTH_KEY_PATH`
  - `LOGOS_APNS_ENV=sandbox` for development builds.
- iPhone can reconnect to the adapter over private network / Tailscale after notification tap.

Validation steps:

1. Launch Logos and tap `Enable` in the Notifications panel.
2. Confirm iOS notification permission prompt appears and allow it.
3. Verify the app receives an APNS device token and sends `register_device` to the adapter.
4. Inspect adapter state/logs and verify:
   - device id is stored,
   - APNS token is stored,
   - the raw token is not echoed back to clients or printed in normal logs.
5. Trigger an assistant completion while the app is backgrounded.
6. Confirm the phone receives a private notification titled `Hermes finished` with body `Open Logos to view the result.`
7. Verify the notification payload contains routing ids only, not response text, summaries, command previews, file paths, or secrets.
8. Tap the notification and verify Logos opens to the correct project/session and runs reconnect + delta sync.
9. Trigger an approval request while the app is backgrounded.
10. Confirm the notification title is `Hermes needs approval`, with no command text in the notification body/payload.
11. Tap it, reconnect, fetch the approval card, and approve/deny from the phone.
12. Trigger a clarification request while backgrounded and verify the same private-payload + reconnect-card flow.
13. Disable APNS credentials and verify the adapter skips live sends without failing the Hermes response path.
14. Repeat over Tailscale with the app foregrounded, backgrounded, and after force-closing/reopening if practical.

Record pass/fail notes in the Stage K/L reports with device model, iOS version, APNS environment, bundle id, and any push/reconnect timing observations. Do not paste device tokens or APNS key material into the report.
