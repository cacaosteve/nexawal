# nexawal

`nexawal` is an iOS Monero wallet built on top of `monero-oxide` and the `MoneroWalletCoreFFI` layer.

- iOS app: this repository
- Android app: [nexawal-android](https://github.com/cacaosteve/nexawal-android)
- Shared wallet core (SPM): [MoneroWalletCoreFFI](https://github.com/cacaosteve/MoneroWalletCoreFFI/tree/walletcore/aligned-2026-07-18) (`walletcore/aligned-2026-07-18`)
- Monero library work: [monero-oxide](https://github.com/cacaosteve/monero-oxide) (fork pin used by the core)

## Setup

```bash
git clone https://github.com/cacaosteve/nexawal.git
cd nexawal
open nexawal.xcodeproj
```

Xcode resolves `MoneroWalletCoreFFI` from GitHub on branch `walletcore/aligned-2026-07-18` (prebuilt xcframework — no Rust required). Use **File → Packages → Update to Latest Package Versions** to move to the tip of that branch.

## Screenshots

| Wallet | Receive |
| --- | --- |
| ![iOS wallet](docs/screenshots/ios1.png) | ![iOS receive](docs/screenshots/ios2.png) |

| Send | Settings |
| --- | --- |
| ![iOS send](docs/screenshots/ios3.png) | ![iOS settings](docs/screenshots/ios4.png) |

## Features

- Single-wallet Monero app (create or import)
- Create-flow seed backup gate (write-down confirmation + word check) before the wallet is persisted
- Optional Face ID / Touch ID for unlock and send
- Classic UI toggle (on = standard look; off = neon terminal theme)
- Clearnet / I2P / hybrid node routing
- Sync status with honest tip/scanned progress; node errors surface when refresh fails
- Receive: QR, copy address, copy payment URI when an amount is set, subaddresses
- Send / send-max with fee preview; prepare → durable persist → relay under the hood
- Transaction details with copy txid and optional explorer link

## Notes

- Uses a native wallet core built from `monero-oxide` via `MoneroWalletCoreFFI`
- Syncs against standard Monero nodes (local or remote), including the configured I2P RPC path when enabled
- Feature parity target: [nexawal-android](https://github.com/cacaosteve/nexawal-android)
