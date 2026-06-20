# Push Notification Sideload Manual Validation

Push registration is device-only — it cannot be exercised in the iOS Simulator —
so verify these on a **free-account sideloaded** device build (no paid Apple
Developer team).

- Enable notifications on a watcher (e.g. a post or your inbox). Confirm the
  flow completes **without** the "Error Loading Notifications — contact
  developer" alert that quotes `no valid "aps-environment" entitlement string`.
- Confirm the notifications/inbox screen loads and watcher CRUD (add, list,
  delete) works as before. Actual push delivery is still expected **not** to
  arrive on a free account — this fix only removes the misleading error and
  unblocks setup.
- Stream the tweak log (`scripts/run-in-sim.sh --logs` on device-equivalent
  tooling, or Console.app) and confirm a single `[Push] Missing aps-environment
  entitlement …` line appears when registration is attempted.
- On a **paid** Apple Developer build (real `aps-environment` entitlement),
  confirm registration succeeds normally and the placeholder path is never hit
  (no `[Push] Missing aps-environment …` log line).
- Force a genuine failure (e.g. airplane mode at registration time) and confirm
  the original error handling still applies — the placeholder substitution must
  only trigger for the entitlement error.
