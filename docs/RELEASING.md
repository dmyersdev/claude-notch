# Releasing

## Everyday: tag it

```bash
git tag v2.1 && git push origin v2.1
```

The **Release** workflow builds a universal app, packages it, and publishes `Claude-Notch-2.1.zip` as a GitHub release with generated notes (edit them afterwards). The **Tests** workflow runs the test suite on every push to `main` and on pull requests.

Without the secrets below, releases are signed ad hoc: people need **Open Anyway** the first time, and macOS asks again for permissions (like controlling Terminal) after each update. `scripts/package.sh <version>` does the same locally.

## One-time: signed and notarized releases

Needs the Apple Developer Program ($99/year).

1. **Developer ID certificate.** In Xcode → Settings → Accounts → Manage Certificates, add a *Developer ID Application* certificate. Export it from Keychain Access as a `.p12` with a password.
2. **Notary API key.** In App Store Connect → Users and Access → Integrations → App Store Connect API, create a key with the *Developer* role. Download the `.p8` (you only get one chance) and note the Key ID and Issuer ID.
3. **Repository secrets** (GitHub → Settings → Secrets and variables → Actions):

   | Secret | Value |
   |---|---|
   | `DEVELOPER_ID_CERT_P12` | `base64 -i cert.p12 \| pbcopy`, then paste |
   | `DEVELOPER_ID_CERT_PASSWORD` | the `.p12` password |
   | `SIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` (see `security find-identity -v -p codesigning`) |
   | `NOTARY_KEY_P8` | the contents of the `.p8` file |
   | `NOTARY_KEY_ID` | the Key ID |
   | `NOTARY_ISSUER` | the Issuer ID |

The next tag produces a release signed with your Developer ID (hardened runtime, Apple Events entitlement for focusing terminal tabs), notarized and stapled: it opens with no warning, and permissions survive updates.

## Later: automatic updates (Sparkle)

Once releases are signed, [Sparkle](https://sparkle-project.org) can update the app in place:

1. Add Sparkle 2 as a Swift package in `project.yml`, an `SPUStandardUpdaterController`, and a **Check for Updates…** menu item.
2. Generate an EdDSA key pair with Sparkle's `generate_keys`. Put the public key in `Info.plist` as `SUPublicEDKey`, and the private key in a `SPARKLE_PRIVATE_KEY` secret. Never commit it.
3. Have the release workflow run `sign_update` on the zip and publish an `appcast.xml` (to GitHub Pages, or as a release asset at a stable URL set as `SUFeedURL`).

The feed must be readable without logging in, so automatic updates need either a public repo or a public place for the appcast and zips.
