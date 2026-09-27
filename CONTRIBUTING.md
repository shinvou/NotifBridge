# Contributing

Start with the hardware, SDK and signing requirements in the README. Generated
Xcode projects and build outputs are not committed. Keep developer-team settings,
provisioning profiles, logs and personal notification data out of pull requests.

Before submitting changes:

1. Regenerate affected projects with XcodeGen and build the affected apps.
2. Run `bash scripts/test-offline.sh` on Apple silicon/macOS 26+.
3. For firmware changes, run `bash scripts/esp32-build.sh` (set `PIO` if needed).
4. For transport changes, test on paired hardware and describe the exact stages
   observed: iPhone forwarding, Mac acceptance, Notification Center retention,
   visible banner, sound, or action result. State what was not tested.
5. Use a conventional commit title such as `fix: preserve notification order`.

The setup UI test is an opt-in real-device driver, not an unattended CI test. It
can change Bluetooth and notification-forwarding permissions. Do not run it
against someone else's configured device without their authorization.

## Bug reports

Include OS/Xcode versions, relay board, commit/version, steps to reproduce and
whether the issue affects all notifications or one app. State whether the iPhone
was locked, disconnected, or recently restarted. Redact message contents, device
identifiers, keys and personal information before attaching logs or screenshots.

Please report security issues privately to the maintainer rather than posting
keys or sensitive notification data in a public issue. The maintainer's contact
is available on the repository owner's GitHub profile.
