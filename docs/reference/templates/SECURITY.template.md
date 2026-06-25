<!--
SECURITY template.

Copy to a new project's repo root as `SECURITY.md`. Replace `{ … }` placeholders.
-->

# Security policy

## Reporting a vulnerability

**Please do not open public issues for security vulnerabilities.**

Email **{security@example.com}** with:

- A description of the vulnerability and its impact.
- Reproduction steps or a proof-of-concept.
- The affected version(s).
- Your name (for credit, if desired) and contact details.

We acknowledge reports within **2 business days** and aim for a fix within **30 days** for high-severity issues. We'll keep you informed of progress.

### Encrypted email

For sensitive disclosures, our PGP key:

```
{Paste the public key block, or link to it on a keyserver:}

Key ID:       {0xABCD1234EFGH5678}
Fingerprint:  {ABCD 1234 EFGH 5678  …}
Download:     https://example.com/security.asc
```

---

## Scope

In scope:

- The {Project} app, daemon (`{project}d`), and all libraries under the {Project}Kit Swift Package.
- The wire protocol (`docs/api.md`) and pairing flow (`docs/pairing.md`).
- The hook server, IPC sockets, and remote-control endpoints.
- Authentication, token storage (Keychain), TLS handling.

Out of scope (do not report):

- Vulnerabilities in dependencies (file upstream, then we'll patch).
- Issues requiring physical access to an unlocked device.
- Self-XSS in fields the user controls and only the user sees.
- Issues in third-party services we integrate with (file upstream).

---

## Supported versions

We patch security issues in:

- The current `main` branch.
- The latest released minor version.
- The previous minor version (until the next minor is released + 30 days grace).

| Version | Supported |
| --- | --- |
| 1.2.x | ✅ |
| 1.1.x | ✅ |
| 1.0.x and earlier | ❌ |

---

## Threat model summary

{Project} operates with the following trust assumptions:

- **The local user is trusted.** {Project} runs with the user's privileges and has no privilege boundary against the user.
- **The local machine is trusted.** Local files, sockets in `$TMPDIR`, and Keychain items are considered secure if the OS account is secure.
- **Network peers are untrusted.** Any remote control client must complete pairing (see [`lan-pairing-and-auth`](docs/reference/patterns/lan-pairing-and-auth.md)) and present a valid bearer token over TLS.
- **Subprocesses (`claude` and adapters) are partially trusted.** They run with the user's privileges but are kept in their own process group so we can terminate the whole tree.

---

## Reproducibility and binary integrity

- Builds are reproducible from the tag: `git checkout v1.2.3 && make release` produces a binary matching the released DMG's SHA.
- Releases are notarised by Apple (when applicable) and signed with the {Project} Developer ID (`{Team ID}`).
- The notarisation ticket and Developer ID signature can be verified:
  ```bash
  spctl --assess --type execute --verbose=4 /Applications/{Project}.app
  codesign --verify --verbose=4 /Applications/{Project}.app
  ```

---

## Hardening guidance

If you operate {Project} in security-sensitive environments:

- Disable headless / API mode (`headlessPort = 0` in prefs) unless required.
- Pair only over isolated networks; treat pairing PINs as one-shot secrets.
- Rotate bearer tokens periodically via the Settings → Devices panel.
- Audit `~/Library/Application Support/{bundleID}/` and the Keychain group periodically.

---

## Acknowledgements

We credit reporters in `CHANGELOG.md` unless they request anonymity:

- {name}, {date}, {brief description of issue}
- {name}, {date}, {brief description of issue}
