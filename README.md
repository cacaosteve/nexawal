# nexawal

`nexawal` is an iOS Monero wallet built on top of `monero-oxide` and the `MoneroWalletCoreFFI` layer.

- iOS app: this repository
- Android app: [nexawal-android](https://github.com/cacaosteve/nexawal-android)
- Rust wallet core / Swift package: [WalletCoreFFI](https://github.com/cacaosteve/WalletCoreFFI)
- Monero library work: [monero-oxide](https://github.com/cacaosteve/monero-oxide)

## Screenshots

| Wallet | Receive |
| --- | --- |
| ![iOS wallet](docs/screenshots/ios1.png) | ![iOS receive](docs/screenshots/ios2.png) |

| Send | Settings |
| --- | --- |
| ![iOS send](docs/screenshots/ios3.png) | ![iOS settings](docs/screenshots/ios4.png) |

## Notes

- Single-wallet Monero app
- Uses a native wallet core built from `monero-oxide`
- Uses `MoneroWalletCoreFFI` to bridge the Rust core into Swift
- Syncs against standard Monero nodes, including local or remote nodes
