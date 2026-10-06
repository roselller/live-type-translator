# TranslateBar

A macOS menu bar app that translates selected English text into one to three
languages using Apple's on-device FoundationModels framework. Translation starts
on demand when you press a shortcut.

Targets: Simplified Chinese, Traditional Chinese, Japanese, and Korean, with a
fixed polite/formal register. No cloud APIs, API keys, analytics, or third-party
packages are used.

## Use it

1. Choose one to three target languages from the menu. New choices go last;
   deselect and reselect to reorder.
2. Select English text and press **Control–Option–T**, or your saved shortcut.
   A pointer badge shows progress. Keep the source app and selection unchanged.
3. Review translations and notes. Click a highlighted phrase to choose an
   alternative when one is available.
4. Press **Return** to insert all languages or **Option–Return** for the displayed
   language. **Esc**, Cancel, and the window's **×** cancel. **Left/Right** switches
   languages.

Insertion keeps the original English and adds translations below the selection
as one plain-text paste. It never simulates Return in the source editor. To place
a translation below each paragraph, select and translate one paragraph at a time.

In Google Docs tables, select **text inside one cell**. Detected table fragments
and tab-separated selections are stopped before translation; inserting across
multiple cells is unsupported. Plain-line copies can conceal cell boundaries,
so avoid selecting whole cells even when no warning appears.

With no selection, Document mode captures the current paragraph; Chat mode
captures the whole input. Unknown apps use Document mode. To configure a chat
app, focus its input, open the TranslateBar menu, and choose **Treat this app as:
Chat**. An override applies to the whole app, including all browser tabs.

Settings includes an audience/glossary profile and a JSON app-rules editor.
Close Settings before translating. Recent results hold the last ten requests in
memory. Reopening a result requires review and uses the **current destination**.
History clears on quit.

## Change the shortcut

Open **Settings → Shortcut → Record shortcut**, press a combination, then choose
**Save shortcut**. Use a letter, number, or F1–F20 with at least two modifiers,
including Control or Command. Esc stops recording. Closing Settings discards an
unsaved change. Labels use US physical key positions, independent of input method.

The previous shortcut remains active until the new registration and save both
succeed. Reserved or conflicting combinations show an error. If another app
intercepts a combination before the recorder sees it, choose a different one.
**Translate now** in the menu remains available when shortcut registration fails.

## Build and install

Requirements: Apple silicon, macOS **27 or later**, Xcode 27 with its macOS SDK,
and the system's on-device language model enabled and downloaded. This is an
unsandboxed personal-use app. Accessibility permission is required for clipboard
keystrokes.

Create or choose a persistent Code Signing identity in Keychain Access. For a
local self-signed certificate, use **TranslateBar Local Development** as its name,
**Self Signed Root** as its identity type, and **Code Signing** as its certificate
type. Confirm that it has an associated private key in the login keychain. If it
is not trusted for signing, set only its **Code Signing** trust to **Always Trust**
and authenticate. An existing valid Apple Development identity also works.

Confirm the identity appears in:

```sh
security find-identity -v -p codesigning
```

Put its exact name on one line in a local `signing.local` file. Keep that file and
all certificates and keys out of Git. Builds reject ad-hoc signing and missing or
invalid identities. Then run from the repository root:

```sh
./scripts/test.sh
CONFIGURATION=release ./scripts/install.sh
```

Enable `~/Applications/TranslateBar.app` in System Settings → Privacy & Security
→ Accessibility (Device Control and Data Access on some systems). Open the app
if needed; it has a menu bar icon and no Dock icon. If a previous installation
used a different bundle identifier, remove its old permission entry and grant
the newly installed app. Saved preferences start fresh after an identifier change.

Scripts use `/Applications/Xcode.app/Contents/Developer` through `DEVELOPER_DIR`
without changing the system's `xcode-select`. Override `DEVELOPER_DIR` if needed.
Keep the same signing identity, bundle identifier, and install path across
updates so permissions can persist. The installer waits for clipboard cleanup
before replacing a running app. Local self-signed builds are not notarized.

Build without installing with `CONFIGURATION=release ./scripts/build.sh`.
Native service tests need a normal macOS session with pasteboard services.

## Privacy and error handling

- Captured text, translations, and recent results stay in memory. Text and window
  titles are never written to files or ordinary logs.
- Only language order, shortcut, profile, and app rules are saved under
  `~/Library/Application Support/local.translatebar.TranslateBar/`.
- The full clipboard is snapshotted and restored. Temporary paste writes carry
  transient/concealed markers; clipboard managers can still observe the source
  app's copy operation.
- Outside typing, clicks, and app changes cancel pending insertion. The panel
  hides before the original foreground app and available focus/selection data
  are rechecked.
- One guided model call normally supplies all targets. Invalid results get one
  retry; separate calls per language are reserved for actual context overflow.
  Incomplete or clearly wrong-language results are rejected before insertion.
- The model can decline valid text. A refusal shows an error and inserts nothing.
  Translation quality and glossary compliance still need human review.
- Permission, unavailable-model, clipboard-access, and settings failures show an
  actionable message. Unreadable settings are preserved until explicitly repaired.

## Verification

Automated tests cover validation, private pasteboard fixtures, settings, shortcut
replacement, and native panel lifecycle. They do not establish compatibility with
every editor. Test these behaviors in each app you use:

- Translate a selection and a paragraph without a selection; confirm scope.
- Check that English and its formatting stay intact and translations appear once.
- Test Return, Option–Return, Esc, Cancel, and the review window's close button.
- Verify the original rich-text and image clipboard after insertion or cancellation.
- Check one-step Undo and that pasting into a chat input never sends a message.
- Change and save a shortcut, restart, and confirm it persists. Try an unavailable
  shortcut and verify the previous one still works.
- Test empty input, long input, slow key release, repeated shortcut presses,
  switching apps during translation, and denied clipboard access.

Fixed-fixture checks print only result/count/timing metadata:

```sh
open -n -g -W build/TranslateBar.app --args --diagnostics
open -n -g -W build/TranslateBar.app --args --smoke-shortcuts
open -n -g -W build/TranslateBar.app --args --smoke-review
open -n -g -W build/TranslateBar.app --args --smoke-settings
build/TranslateBar.app/Contents/MacOS/TranslateBar --benchmark-model
```

Native panel checks use temporary preferences and fixed translations. Shortcut
checks briefly register test combinations without sending keystrokes to editors.
Benchmark timings depend on model readiness, workload, and system/model updates.

## License

Licensed under the [MIT License](LICENSE). Copyright (c) 2026 roselller.

## Security reports

See [SECURITY.md](SECURITY.md) for the vulnerability-reporting process. Reports
use restricted repository issues while this repository is private and are visible
to all collaborators. Keep sensitive details out of public channels.
