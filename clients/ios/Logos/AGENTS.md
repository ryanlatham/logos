# Logos iOS Notes

- The conversation thread auto-follows the newest visible item by default. New visible thread state belongs in `ThreadTimelineSnapshot`; do not add one-off `.onChange` scroll hooks for messages, progress, cards, acks, errors, voice drafts, or composer/layout state.
- Auto-follow detaches only for user-driven scrolling farther than `ThreadAutoFollowPolicy.detachThreshold`, currently `max(160pt, 25% of visible scroll height)`. Programmatic layout movement and small offsets should keep following.
- User prompt submission and tapping "New updates" are force-follow paths. After any scheduled follow, the second layout pass must be cancelled if the user detaches before it runs.
- Completed progress cards must carry the matched final assistant message id and render immediately before that message. Later unrelated assistant messages must not move an older completed progress card.
- Keep durable tool progress out of normal assistant bubbles; it belongs in the progress card.
