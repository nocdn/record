# record

Record the primary Mac display, system audio, microphone, and mouse cursor from
a single npm command. The package bundles a headless native `Record.app`, so
runtime dependencies are only macOS 15+, Node.js, and npm.

## Install and run

Run without installing:

```bash
npx @nocdn/record
```

## Usage

```bash
npx @nocdn/record [options]
npx @nocdn/record --only-mic
npx @nocdn/record mics
npx @nocdn/record permissions
```

| flag | description |
| --- | --- |
| `-h`, `--help` | show help |
| `-v`, `--version` | show version |
| `-o`, `--output <path>` | save to a specific path instead of the default location |
| `--only-mic`, `--mic-only`, `--microphone` | record only the microphone into the current directory |
| `--no-mic` | disable microphone capture |
| `--mic <name>` | select a microphone by name; default is the built-in Mac microphone, not the current system input |
| `--list-mics` | list microphones that `--mic` can select |
| `--no-system-audio` | disable system/application audio |
| `--display <number>` | select a display, starting at `1` |
| `--fps <number>` | set the frame rate, from greater than `0` through `120` |
| `--format <mp4\|mov>` | choose the output container |
| `--no-cursor` | hide the mouse cursor |

With no flags, the command records the primary display at native resolution,
system audio, and the built-in Mac microphone (not whichever input macOS
currently has set as default), with a visible cursor, at 30 fps, H.264/AAC,
MP4, and a timestamped file in `~/Movies`. `--no-mic` and `--no-system-audio`
turn those audio sources off.

`--only-mic` skips the screen and system audio and writes a timestamped `.m4a`
file in the current working directory. Combine it with `--mic <name>` to pick a
specific microphone, or `-o` to choose a path. Names can be a full device name
or a unique substring, for example `--mic "AirPods"`.

List the devices `--mic` can use:

```bash
npx @nocdn/record mics
```

Stop with `Ctrl+C`. The first interrupt asks the native recorder to finalize
the media file; a second interrupt is an emergency force quit and may leave an
unusable file.

## Permissions

The first run may ask for Screen Recording and Microphone access. If Screen
Recording access is granted while a recording is being prepared, the command
may need to be run again so macOS restarts the native recorder with the new
permission.

Check the current state without starting a recording:

```bash
npx @nocdn/record permissions
```

Permissions are assigned to the bundled `Record.app`, which is deliberately a
background-only app with no window, Dock icon, or menu-bar item.

## Develop

```bash
npm install
npm run build
npm start
npm test
```

The CLI entry point lives in [`bin/cli.js`](./bin/cli.js), and the native source
lives in [`native/record-native.swift`](./native/record-native.swift). `npm run
build` compiles arm64 and x86_64 helpers, combines them into a universal binary,
creates `vendor/Record.app`, and applies an ad-hoc signature by default. Set
`RECORD_SIGNING_IDENTITY` to a Developer ID Application identity for a signed
distribution build; non-ad-hoc builds use the Hardened Runtime and a secure
timestamp. After a Developer ID build, `npm run notarize` submits the app to
Apple and staples the ticket.

The package is intentionally built with plain ESM JavaScript and native Apple
frameworks; it has no npm runtime dependencies and does not require FFmpeg,
Homebrew, Xcode, or a virtual audio driver on the recording machine.

## Publishing

[`.github/workflows/publish.yml`](./.github/workflows/publish.yml) runs on a
GitHub-hosted `macos-26` runner so it can compile the Swift helper. On `main`,
when `package.json` has a version that is not already on npm, the workflow
signs `Record.app` with Developer ID, notarizes it, staples the ticket, and
publishes with [trusted publishing](https://docs.npmjs.com/trusted-publishers).
Pull requests only compile and test; they do not notarize or publish.
`package.json` sets `publishConfig.access` to `public`.

Signing and notarization are what stop Gatekeeper from showing “Apple could
not verify” / “malware” when someone runs the helper from npm. They do **not**
skip macOS Screen Recording or Microphone prompts. Those are separate Privacy
& Security permissions and still appear on first use.

To enable a release once:

1. Push the repository to GitHub.
2. Add a `repository.url` field to `package.json` that exactly matches the
   GitHub repository URL.
3. On npmjs.com, configure the package as a GitHub Actions trusted publisher:
   use this repository owner/name, workflow filename `publish.yml`, and allow
   `npm publish`.
4. Add these repository secrets (Settings → Secrets and variables → Actions):

   | secret | value |
   | --- | --- |
   | `APPLE_DEVELOPER_ID_P12` | base64 of the exported Developer ID Application `.p12` |
   | `APPLE_DEVELOPER_ID_P12_PASSWORD` | password for that `.p12` |
   | `APPLE_API_KEY` | contents of the App Store Connect API `.p8` key |
   | `APPLE_API_KEY_ID` | the key id, for example `AB12CD34EF` |
   | `APPLE_API_ISSUER` | the issuer UUID from App Store Connect (required for team keys) |

   Instead of the API key trio you can set `APPLE_ID` and
   `APPLE_APP_SPECIFIC_PASSWORD`. The workflow already uses team id
   `7CAU3XFRLQ` and identity `Developer ID Application: Bartosz Bak (7CAU3XFRLQ)`.

   Export the certificate from Keychain Access → My Certificates →
   **Developer ID Application: Bartosz Bak**. Include the private key, set a
   password, then:

   ```bash
   base64 -i developer-id.p12 | pbcopy
   ```

   Create an App Store Connect API key at
   [Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api)
   with at least the Developer role. The `.p8` file can be downloaded only
   once.

5. Bump the version in `package.json` and push to `main`. The workflow
   publishes without an npm token.

`npm publish` runs `prepack`, which would rebuild and drop the stapled ticket.
The workflow sets `RECORD_SKIP_NATIVE_BUILD=1` so the already notarized
`vendor/Record.app` is what gets packed.
