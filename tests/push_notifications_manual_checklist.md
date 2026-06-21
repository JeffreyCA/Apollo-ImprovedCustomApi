# Push Notification Sideload Manual Validation

Push registration is device-only — it cannot be exercised in the iOS Simulator —
so verify these on real builds.

## Free-account sideload (no `aps-environment` entitlement)

- Open **Settings → Notifications**. Confirm it shows the non-interactive
  **"Notifications Unavailable"** screen (bell.slash icon + explanation) instead
  of the live controls.
- Confirm **no** "Error Loading Notifications — contact developer" alert appears
  (the one that quotes `no valid "aps-environment" entitlement string`).
- Confirm the explanatory screen swallows taps — nothing underneath can be
  toggled — and that the navigation bar / back button still work.
- Stream the tweak log (`scripts/run-in-sim.sh --logs` on device-equivalent
  tooling, or Console.app). Confirm a `No aps-environment entitlement … replacing
  the Notifications screen` line appears, and — if registration is attempted — a
  single `Missing aps-environment entitlement … Suppressing the misleading
  registration error` line (and **no** "contact developer" alert).

## Paid Apple Developer sideload (real `aps-environment` entitlement)

- Open **Settings → Notifications**. Confirm the **stock** notifications screen
  appears unchanged (no "Notifications Unavailable" overlay) and registration
  succeeds normally.
- Confirm the suppression path is never hit (no `Missing aps-environment …` or
  `replacing the Notifications screen` log lines).

## Genuine failures are unaffected

- Force a real registration failure (e.g. airplane mode at registration time on
  a paid build) and confirm Apollo's original error handling still applies — the
  entitlement-error suppression must trigger *only* for the missing-entitlement
  case, never for transient failures.
