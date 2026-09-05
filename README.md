# Voform

Voform is a macOS 14+ menu-bar voice input app. By default, press **Option-Space (⌥ Space)** to start dictation, release the keys and speak, then press it again to finish and insert the transcript into the focused field.

Open **Settings… → General** to configure these independently:

- **Dictation shortcut:** click **Record…** and press a modifier-key combination, or click **Use Fn**. Choose a combination that is not already used by another app.
- **Recording mode:** **Press to toggle** starts and finishes with separate presses; **Hold to talk** records while held and finishes on release.

During recording, press **Esc** or click **Cancel** to discard the recording without inserting text. Click **Finish** to stop and insert text. The floating panel stays visible while listening and shows transcription/refinement progress after finishing. New recording requests are ignored while processing.

With **Fn / Globe + Press to toggle**, only a standalone tap (released within 0.5 seconds) starts or finishes recording. Holding Fn or using Fn with another key does not toggle recording. Fn events remain available to macOS for function-key combinations: in **System Settings → Keyboard**, set the standalone **Press Globe key to** action to **Do Nothing** to avoid also switching input sources or opening emoji/dictation. External keyboards that do not expose Fn to macOS should use a regular key combination instead. With **Fn + Hold to talk**, Fn starts recording immediately; adding another key cancels that recording without inserting text.

Updating from the previous version changes the old Fn default to ⌥ Space and initially selects toggle mode. Other custom shortcuts are preserved. Shortcut/mode changes or suspending shortcut monitoring cancel an active recording; sleep and switching away from the user session also cancel it.

The unified Settings window contains recognition language and shortcut controls under **General**, the refinement toggle and OpenAI-compatible connection details under **AI Refinement**, and live permission status with direct System Settings links under **Privacy**.

## Build and run

```sh
make build
make run
```

The locally signed app bundle is written to `dist/Voform.app`. Install it with `make install`.

## Local code-signing identity

Voform requires a stable, self-signed **Code Signing** identity so macOS privacy permissions survive rebuilds. On the first build, the signing script scans the keychains for valid self-signed code-signing identities that have an associated private key:

- If exactly one is available, it is selected automatically.
- If several are available, the script asks you to choose one.
- You can choose explicitly with `make build SIGN_IDENTITY="Certificate Name"` or its SHA-1 fingerprint.
- Change the saved selection later with `make signing-identity`.

The selected certificate name and SHA-1 fingerprint are saved in `.voform-signing-identity`. This local file is gitignored and must not be committed.

If no usable identity exists, create one in **Keychain Access → Certificate Assistant → Create a Certificate…**. Select **Self Signed Root** as the identity type and **Code Signing** as the certificate type. Confirm that a private key appears beneath the certificate, and set its Code Signing trust to **Always Trust** if required. Verify it with:

```sh
security find-identity -v -p codesigning
```

On first launch, grant Microphone, Speech Recognition, Accessibility, and Input Monitoring permissions. Because these permissions are associated with the app's code signature and path, run the installed app from a stable location such as `/Applications` for regular use.

Simplified Chinese (`zh-CN`) is the default recognition language. Other languages and optional OpenAI-compatible LLM refinement are available from the menu-bar menu.

## Validation

Run `swift test --disable-sandbox` for gesture regression tests. On a Mac with microphone, speech, and keyboard permissions granted, verify both recording modes, Fn+function-key combinations, Escape cancellation, and the floating Finish/Cancel controls in your usual text editor.
