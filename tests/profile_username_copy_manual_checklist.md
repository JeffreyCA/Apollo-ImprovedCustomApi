# Profile username copying

- Match [PR #202](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/202):
  hold the username to open the **Copy Username** context menu, then select
  that action to copy the bare account username, without `u/`.
- Start in Native with Show User Profile Pictures off. Hold the navigation
  username (including the Liquid Glass pill), cancel the menu, and confirm the
  clipboard is unchanged. Open it again and select **Copy Username**.
- Repeat in Immersive and Compact using the visible large name. Merely holding
  or dismissing the menu must never change the clipboard.
- In all three styles, the name must stay at its original size and position
  throughout menu opening, selection, and cancellation: no zoom, clipped text,
  duplicate name, blank flash, or return-flight animation. Include long display
  names/usernames and both the Native Liquid Glass pill and plain title.
- Test a profile whose display name differs from its username. Holding either
  name line must offer the menu; its action copies the account username, never
  the display name.
- Keep holding, then release: no automatic copy or extra success-haptic pattern.
  A short tap or a scrolling drag must not copy anything.
- Scroll until the navigation title appears and hold it. Repeat with detailed
  profiles disabled (Native layout), and on your own profile.
- Switch Native ↔ Immersive ↔ Compact, scroll the title in/out, and reopen the
  screen repeatedly. Expect one menu per hold and no menu on an invisible title.
- Switch accounts or open another user's profile and repeat. Never copy the
  previous account's username; a menu left open across a title reuse must not
  copy a different account. Missing/deleted usernames must not offer a menu.
- With VoiceOver, use the name's **Copy Username** action and confirm the
  clipboard and the “Username copied” announcement.
- The Profile Layout settings preview must not offer a copy menu or change the
  clipboard; its own pin/unpin interaction remains separate.
- Confirm the system menu feedback on a physical iPhone; the simulator cannot
  reproduce physical haptics. Test both Liquid Glass and standard builds.
