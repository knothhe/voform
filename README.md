# Voform

Voform is a macOS 14+ menu-bar voice input app. Hold the configured shortcut key to dictate and release it to paste the transcript into the focused field.

The default shortcut is **Fn / Globe**. Open **Settings… → General**, click **Record…**, and press another key combination to customize it. **Option-Space (⌥ Space)** is a useful fallback for external keyboards that handle Fn internally and do not expose it to macOS.

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
