# Pattern: LAN pairing and auth

**Scope.** First-time PIN-based device pairing, persistent bearer-token auth, Keychain-pinned self-signed TLS, and lockout for trusted local-network remote control between a host app and a companion device. Designed for the "phone-on-the-same-Wi-Fi-as-the-Mac" use case where heavyweight OAuth would be overkill but plaintext would be unacceptable.

**When to use.** Any host ↔ companion-device pairing over LAN where:

- The user is the only person authenticated.
- The threat model is "neighbour on the same Wi-Fi," not "nation-state."
- A relay server is unavailable or unwanted.
- The host runs an `NWListener` (or equivalent) and the client opens a WebSocket / HTTP connection to it.

**When not to use.** Public-internet services (use a real IdP). Multi-user systems with complex permissions (use a real auth service). One-way control surfaces with no sensitive data (you may get away with plaintext + firewall — but you'll regret it).

---

## The threat model — explicit

| Threat | In scope | Out of scope |
| --- | --- | --- |
| Same-network passive eavesdropper reading frames | ✓ | — |
| Same-network active MITM (ARP spoofing, DNS poisoning) | ✓ | — |
| Brute-force PIN guessing | ✓ | — |
| Token exfiltration via the host's filesystem | ✓ | — |
| Cross-network attacker (router compromise) | partial — TLS + cert pinning helps | full network rooting |
| Compromised companion device | — | hard problem |
| Persistent attacker with physical access to the host | — | hard problem |

The pattern below handles the "in scope" column. If you need more, layer on a third-party SDK; the architecture stays the same.

---

## The four moving parts

1. **TLS certificate** — self-signed, host-generated once, persisted in the host's Keychain. Clients pin its fingerprint.
2. **PIN handshake** — short-lived (90s) numeric code displayed on the host, entered on the client. Constant-time compare, exponential lockout.
3. **Bearer tokens** — per-paired-device long-lived secrets (random 32 bytes, base64-encoded). Hashed in Keychain; revocable per-device.
4. **Bonjour advertisement** — `_app._tcp.local.` with a TXT record indicating pairing state.

Each is independent and replaceable; together they form the trust path.

---

## The TLS certificate

```swift
public enum TLSIdentityStore {

    private static let serviceTag = "com.codecave.Codemixer.remoteControl"

    public static func loadOrCreate() throws -> SecIdentity {
        if let identity = try loadFromKeychain() { return identity }
        return try createAndStore()
    }

    private static func createAndStore() throws -> SecIdentity {
        let (cert, privateKey) = try generateSelfSigned(
            commonName: "Codemixer",
            validity: .years(5)
        )
        try storeInKeychain(cert: cert, privateKey: privateKey, tag: serviceTag)
        return try createSecIdentity(cert: cert, privateKey: privateKey)
    }

    public static func fingerprint() throws -> String {
        let identity = try loadOrCreate()
        let cert = try extractCertificate(from: identity)
        let der = SecCertificateCopyData(cert) as Data
        let hash = SHA256.hash(data: der)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
```

**Properties:**

- **One certificate per host install.** Generated at first listener start, persisted with `kSecAttrAccessibleAfterFirstUnlock`.
- **5-year validity.** Long enough that re-pairing is a deliberate event, short enough that key rotation is possible.
- **No CA chain.** The certificate is its own root. Clients verify via fingerprint pinning, not chain validation.
- **RSA-2048 or ECDSA P-256.** Either is fine; the wider TLS world supports both.

---

## The pairing flow

```
HOST (Mac, codemixerd)                    CLIENT (iPhone Codemixer Remote)

[User taps "Pair new device"]
   ↓
generate 6-digit PIN
expires in 90s
display PIN + QR
   pin = 384519
   QR = codemixer://pair?host=10.0.0.42
                          &port=8421
                          &fingerprint=abc123…
                          &session=xyz789
   ↓                                      [User scans QR]
   ↓                                       reads host, port, fingerprint, session
   ↓                                       opens wss://10.0.0.42:8421/v1/ws
   ↓                                       TLS handshake → verify fingerprint
   ↓                                            (fail = abort with clear UI)
   ◀──────────────── ClientHello, etc. ─────
   ╶────────────── ServerHello + cert ─────▶  pinned-cert check
   ◀──────────────── PairRequest ───────────  { pin: "384519", deviceName: "Codemixer Mobile" }
constant-time compare
   if mismatch:
      record attempt
      if >= 5 attempts:
         start lockout (60s, doubling)
      respond: PairError(.invalidPIN, retryAfter: …)
   if match:
      generate random 32 bytes → token
      store sha256(token) in Keychain
      under: {deviceName, createdAt, lastSeen}
   ─────────────── PairOK { token, sessionInfo } ─────▶  persist token in Keychain (user-protected)
                                                          close connection
                                                          (next reconnect uses bearer token)
[User confirms in UI: "Codemixer Mobile paired"]
   ↓
PIN invalidated
```

**Properties:**

- **PIN is 6 digits**, generated from `SecRandomCopyBytes`, decimal-modulo-reduced.
- **PIN expires after 90 seconds** to limit brute-force time.
- **Constant-time compare** via `CryptoKit.HashedAuthenticationCode` or `CC_compare`-style; never `==`.
- **5 attempts trigger lockout**; lockout doubles each cycle (60s → 120s → 240s → …). After two cycles, the host requires the user to tap a *new* "Pair new device" button — a one-shot UX gate.
- **Bearer token is 32 random bytes**, base64-encoded for the wire. Only the **SHA-256 hash** is persisted on the host; the host never sees the plaintext after pairing closes.
- **Token persistence on the client** uses iOS Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Never plain `UserDefaults`.
- **Device name** is user-editable both sides. The host displays it in the *Paired devices* list.

---

## The bearer-token authentication

After pairing, every subsequent connection authenticates with the bearer token:

```
CLIENT                                     HOST

opens wss://host:port/
TLS handshake → fingerprint pin
   ◀──────────────── ClientHello ──────────
   ╶────────────── ServerHello ───────────▶
   ◀──────────────── Authenticate ─────────  { token: "base64..." }
                                              compute sha256(token)
                                              lookup in Keychain
                                              if match → update lastSeen, accept
                                              if mismatch → close with 401
   ─────────────── AuthOK { sessionID } ───▶  proceed to subscribe / command frames
                                              or
   ─────────────── AuthError(.invalid) ────▶  show "Re-pair this device" in UI
```

**Properties:**

- **Tokens never travel in URL parameters.** Always inside the first authenticated frame.
- **Re-auth on every reconnect.** No "session cookies."
- **Per-device revocation.** Host's *Paired devices* list lets the user delete any token; the next connect from that device gets a 401.
- **Auto-expire after N days inactive** (default 90 days). Lapsed devices must re-pair.

---

## The host-side Keychain layout

```
Service: com.codecave.Codemixer.remoteControl

Items:
  ├── "tls-identity"                      kSecClassIdentity, SecIdentity
  ├── "device-{deviceID}"                 kSecClassGenericPassword
  │     account = deviceName
  │     valueData = sha256(token)
  │     attributes:
  │       createdAt: Date (kSecAttrCreationDate)
  │       lastSeen:  Date (kSecAttrModificationDate)
```

Properties:

- **Access control**: `kSecAttrAccessibleAfterFirstUnlock` for the TLS identity (the daemon needs it pre-login on subsequent boots); `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for device tokens.
- **No Keychain sharing groups.** The daemon and GUI are the same code-signing identity, accessing the same default group.
- **Backup-safe.** Tokens hashed before storage; backups don't leak plaintext.

---

## Bonjour advertisement

```swift
public actor BonjourAdvertiser {
    private var listener: NetListener?
    private var browser: NWBrowser?
    private var service: NetService?

    public func start(port: UInt16, paired: Int) {
        let txt = NetService.dictionary(fromTXTRecord: [
            "v": "1".data(using: .utf8)!,
            "device": Host.current().localizedName?.data(using: .utf8) ?? Data(),
            "pairingState": (paired > 0 ? "paired" : "open").data(using: .utf8)!,
        ])
        service = NetService(domain: "local.", type: "_codemixer._tcp.", name: "Codemixer", port: Int32(port))
        service?.setTXTRecord(txt)
        service?.publish()
    }

    public func stop() {
        service?.stop()
        service = nil
    }
}
```

**Properties:**

- **Type** is project-unique (`_codemixer._tcp.`). Choose your own.
- **TXT record carries protocol version** so a future v2 client can ignore v1 hosts.
- **`pairingState`** lets the client UI hide hosts that aren't accepting new pairings.
- **Start / stop in lockstep with the listener.** Never advertise a non-listening service.

---

## Configuration toggles

The user controls three switches:

| Toggle | Default | Effect |
| --- | --- | --- |
| **Enable remote access** | Off | When on: start listener (loopback only), start Bonjour advertisement. |
| **Allow LAN connections** | Off | When on: rebind listener to LAN address (`0.0.0.0:8421`) in addition to loopback. |
| **Enable on login** | Off | When on: install LaunchAgent so the daemon starts at login. |

**Rebinding is fast.** Toggling LAN on/off restarts the listener with new params within 100ms. The pattern: `await listener.cancel(); listener = makeListener(); try await listener.start()`. Active connections survive (they're already inside the existing socket); new connections honour the new binding.

---

## Lockout state machine

```swift
public actor LockoutTracker {

    private struct Attempt { let at: Date }

    private var attempts: [Attempt] = []
    private var lockedUntil: Date?
    private let clock: any Clock

    public func recordFailure() async -> LockoutAction {
        let now = clock.now()
        attempts.append(Attempt(at: now))
        attempts = attempts.filter { now.timeIntervalSince($0.at) < 600 }  // 10-min window

        if attempts.count >= 5 {
            let cycle = max(0, (attempts.count - 5))
            let lockoutSeconds = 60 * (1 << cycle)   // 60, 120, 240, 480…
            lockedUntil = now.addingTimeInterval(TimeInterval(lockoutSeconds))
            return .lockedOut(seconds: lockoutSeconds)
        }
        return .allowedWithRemaining(5 - attempts.count)
    }

    public func canAttempt() async -> Bool {
        guard let until = lockedUntil else { return true }
        return clock.now() >= until
    }

    public func recordSuccess() async {
        attempts.removeAll()
        lockedUntil = nil
    }
}

public enum LockoutAction: Sendable, Equatable {
    case allowedWithRemaining(Int)
    case lockedOut(seconds: Int)
}
```

**Properties:**

- **Per-host, not per-client.** Attackers can switch IPs; the host tracks attempts in aggregate.
- **Sliding 10-minute window.** Stale failures expire so legit fumbles don't accumulate.
- **Exponential backoff.** Each lockout cycle doubles. After 4 cycles (~ 16 min total), the UI requires manual reset.
- **Successful pair clears the slate.** No history baggage.

---

## Error model

```swift
public enum PairingError: Error, Codable, Sendable {
    case invalidPIN(retryAfterSeconds: Int)
    case pinExpired
    case lockedOut(retryAfterSeconds: Int)
    case fingerprintMismatch(expected: String, got: String)
    case alreadyPaired
    case rateLimited
}

public enum AuthError: Error, Codable, Sendable {
    case unauthorized
    case tokenRevoked
    case tokenExpired
    case versionMismatch(server: Int, client: Int)
}
```

Clients show user-actionable messages from these:

- `invalidPIN` → *"PIN doesn't match. 3 attempts remaining."*
- `lockedOut` → *"Locked. Try again in 4:32."*
- `fingerprintMismatch` → *"This host's certificate has changed. Re-pair if you trust it."*

Never expose stack traces; the typed error case carries everything the client needs.

---

## Logging

Pairing and auth events are logged with `os.Logger`:

```swift
log.info("pair_attempt deviceName=\(name, privacy: .public) pin_correct=\(success, privacy: .public)")
log.warning("pair_lockout cycle=\(cycle, privacy: .public) seconds=\(seconds, privacy: .public)")
log.notice("auth_ok deviceID=\(id, privacy: .public)")
log.warning("auth_fail reason=\(reason.rawValue, privacy: .public)")
```

PIN values, tokens, and full payloads are never logged. Device names are public (the user set them).

---

## Anti-patterns

| Anti-pattern | Why it's bad |
| --- | --- |
| **HTTPS Basic Auth with the PIN as password** | PIN guessable, every request leaks PIN. Use it once for handshake; replace with bearer token. |
| **Storing plaintext token on the host** | Filesystem leak → silent take-over. Only the hash. |
| **Long PINs (e.g. 10 digits)** | Worse UX, marginal security gain. 6 digits + lockout is the sweet spot. |
| **Reusing PINs** | Replay attacks. PINs are one-shot. |
| **OAuth-style refresh tokens** | Overkill for a local pairing. Bearer + revoke list is enough. |
| **Trusting TLS chain validation without pinning** | Self-signed certs can't chain; clients must pin the fingerprint. |
| **Letting `NSURLSession` cache the TLS session** | Cached old certs survive rotation. Pin every connect. |
| **Hard-coding the port** in the QR | Networks block well-known ports; let users override or let the system assign. |
| **Persistent listener on `0.0.0.0` by default** | Exposes the host to the LAN before the user opts in. Loopback default. |

---

## Codemixer instance

- `TLSIdentityStore` ↔ inside `Remote/AgentRemoteControl/PairingService.swift`.
- `PairingService` ↔ `Remote/AgentRemoteControl/PairingService.swift`.
- `BonjourAdvertiser` ↔ `Remote/AgentRemoteControl/BonjourAdvertiser.swift`.
- `RemoteControlServer` ↔ `Remote/AgentRemoteControl/RemoteControlServer.swift`.
- Bearer-token Keychain layout: service `com.codecave.Codemixer.remoteControl`.

See [docs/architecture.md §§21, 23](../../architecture.md) for the Codemixer narrative.

---

## Minimum viable adoption

1. Generate self-signed TLS at first listener start; persist in Keychain.
2. Build `LockoutTracker` first — it's testable in isolation.
3. Build `PairingService` with the constant-time PIN compare.
4. Build the bearer-token authentication path.
5. Add Bonjour advertising in lockstep with the listener.
6. Add the three UI toggles (Enable remote, Allow LAN, Enable on login).
7. Add the *Paired devices* list with revoke action.
8. Add the QR code (encode `host:port:fingerprint:session`) and a manual-entry fallback.
9. Test:
   - Successful pair on first try.
   - Wrong PIN 5 times → lockout.
   - Cert rotation → all paired devices must re-pair.
   - Token revoke → that device's next connect fails 401.

The result: a phone-paired Mac that respects the user's network and doesn't trust the LAN one bit.
