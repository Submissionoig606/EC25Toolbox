# eSTK feature parity

Reference snapshots used for this integration:

- EasyLPAC `0ebf90eaf69f3f06b4dbbf98428a22526f93ced9` (0.8.0.3)
- OpenEUICC `d9c89d311f34325e1bd7e4b35d7e750e72faafac`
- bundled lpac `c2fcf5e4b21c712d54e35a11da2ad9ad134fb821` (2.3.0)

## Implemented in the eSTK page

- Automatic removable-eUICC detection and automatic information refresh
- Complete chip information: EID, configured SM-DP+/SM-DS, EUICCInfo2,
  resources, capabilities, policy rules, EUM manufacturer, and CI issuers
- Copy EID and complete chip JSON
- Profile list with provider, class, icon, state, ICCID, enable, disable,
  nickname, and guarded deletion
- Profile download by LPA activation code or manual SM-DP+ and Matching ID,
  with confirmation code and modem IMEI
- Activation-code import from clipboard and QR-code image
- ES11 SM-DS discovery and reuse of discovered SM-DP+ addresses
- Set the eUICC default SM-DP+ address
- Notification list, send, send-and-remove, remove, process all, remove all,
  and batch removal by operation type
- Per-operation automatic notification policies matching OpenEUICC defaults:
  download on, deletion on, profile switching off
- Standard, 5ber, eSIM.me, and Xesim ISD-R AID presets plus custom AID and
  ES10x MSS
- HTTPS proxy, secure TLS verification by default, and an explicit unsafe
  certificate-verification override
- Redacted in-memory operation/APDU diagnostics
- eUICC memory reset with typed EID-suffix confirmation

## Adapted or excluded platform-specific features

- Android system-LPA, privileged telephony APIs, slot/port mapping, DSDS/MEP,
  Shizuku/root flows, and SIM Toolkit forwarding do not exist on macOS and are
  not presented as eUICC operations.
- PC/SC, Android OMAPI, USB CCID, QMI, MBIM, and serial driver selection are not
  exposed because this application owns one native EC25 USB AT transport. It
  uses `AT+CCHO/CGLA/CCHC` with an `AT+CSIM` fallback.
- Android camera/gallery acquisition is represented by macOS clipboard and
  user-selected QR-image import. No camera permission is requested.
- Raw HTTP/APDU body logging is not exposed because it can contain activation
  secrets or bound profile packages. The page provides a redacted operation
  log and APDU status diagnostics instead.
