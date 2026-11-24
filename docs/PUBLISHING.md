# Publishing BurnBlame

BurnBlame supports three distribution channels from the same codebase:
1. **Notarized Direct `.dmg`** (GitHub Releases) — *Full features (AppleSMC °C/RPM/W, full process forensics, process actions)*
2. **Homebrew Cask** — *One-command install backed by the notarized `.dmg`*
3. **Mac App Store (`.pkg`)** — *Sandboxed edition compiled with `-DAPP_STORE`*

---

## 1. One-Time Apple Developer Setup

### Install Certificates
Open **Xcode → Settings → Accounts → Select your Apple Developer Team → Manage Certificates → `+`**:
- **For Direct / Homebrew:** create **Developer ID Application**
- **For Mac App Store:** create **Apple Distribution** (and create a **Mac Installer Distribution** cert at [developer.apple.com](https://developer.apple.com/account/resources/certificates/list) and double-click to install in Keychain)

Verify they appear in Keychain:
```bash
security find-identity -v -p codesigning
```

### Store Notarization Credentials (One-Time)
Generate an **App-Specific Password** at [appleid.apple.com](https://appleid.apple.com), then save it to your Keychain under the profile `burnblame-notary`:
```bash
xcrun notarytool store-credentials "burnblame-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

---

## 2. Ship a Notarized Direct Release (`.dmg` + GitHub Releases)

1. Bump the version in [`VERSION`](../VERSION) (e.g., `1.0.0`).
2. Build, sign (Universal `arm64` + `x86_64`), notarize, and staple:
   ```bash
   ./scripts/release-direct.sh
   ```
   This produces `dist/BurnBlame-<version>.dmg`, staples the Apple notarization ticket, and prints the **SHA-256**.
3. Create the GitHub Release and upload the `.dmg`:
   ```bash
   gh release create v1.0.0 dist/BurnBlame-1.0.0.dmg \
     --title "BurnBlame v1.0.0" \
     --generate-notes
   ```

---

## 3. Publish via Homebrew Cask

1. Update [`Casks/burnblame.rb`](../Casks/burnblame.rb) with the version and SHA-256 printed by `release-direct.sh`:
   ```bash
   ./scripts/update-homebrew-cask.sh 1.0.0 <SHA256>
   git add Casks/burnblame.rb VERSION
   git commit -m "Release v1.0.0"
   git push
   ```
2. Users can now install directly from this repo:
   ```bash
   brew tap arosemena/burnblame https://github.com/arosemena/burnblame
   brew install --cask burnblame
   ```
   *(Optional: create a dedicated `arosemena/homebrew-tap` repo and copy `Casks/burnblame.rb` into it so users can run `brew install --cask arosemena/tap/burnblame`.)*

---

## 4. Publish to the Mac App Store

1. In [App Store Connect](https://appstoreconnect.apple.com), register a new macOS app with Bundle ID **`mx.lotus.burnblame`**.
2. Create & download a **Mac App Store Distribution Provisioning Profile** for `mx.lotus.burnblame` from developer.apple.com.
3. Build and sign the sandboxed `.pkg`:
   ```bash
   PROVISIONING_PROFILE=/path/to/BurnBlame_MAS.provisionprofile \
     ./scripts/release-mas.sh
   ```
4. Upload `dist/mas/BurnBlame-<version>.pkg` using Apple's **Transporter** app (from the Mac App Store) or via CLI:
   ```bash
   xcrun altool --upload-app \
     -f dist/mas/BurnBlame-1.0.0.pkg \
     -t macos \
     -u "YOUR_APPLE_ID" \
     -p "@keychain:AC_PASSWORD"
   ```

> **Note on Sandbox Differences:** The Mac App Store build compiles with `-DAPP_STORE` and `com.apple.security.app-sandbox = true`. It cleanly disables `AppleSMC` and cross-process `/bin/ps` calls so there are zero sandbox violations while preserving whole-Mac CPU, GPU%, macOS thermal pressure, sparklines, and Heat Log.
