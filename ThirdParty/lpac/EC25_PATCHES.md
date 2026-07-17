# EC25 Toolbox lpac patches

The bundled source is based on lpac v2.3.0 (`c2fcf5e4b21c712d54e35a11da2ad9ad134fb821`).

- `driver/apdu/stdio.c`: invert the `json_print()` result returned by
  `json_request()`. `json_print()` returns `true` on success, while the APDU
  callers use the conventional zero-success result. Without this correction,
  lpac exits immediately after emitting its `connect` request.
- `driver/http/curl.c`: retain TLS certificate and host verification by
  default. Verification is disabled only when EC25 Toolbox explicitly sets
  `LPAC_HTTP_INSECURE` from its advanced compatibility setting.
- EC25 Toolbox selects lpac's `stdio` HTTP driver and executes ES9+ through
  native `URLSession`, keeping system trust evaluation and proxy handling out
  of the lpac child process. The curl driver remains available standalone.
- ES9+ trust evaluation augments the macOS system trust store only with GSMA
  eSIM CI roots supported by the connected eUICC. RSP2 Root CI1 is always
  included for compatibility with cards that omit it from EUICCInfo2, matching
  OpenEUICC's trust-store behavior; hostname and chain validation remain active.
- URLSession's legacy ATS WebPKI-only gate is disabled because GSMA CI roots
  intentionally live outside Apple's WebPKI. The native bridge accepts HTTPS
  URLs only and performs its own host, chain and GSMA-anchor validation.
- EC25 Toolbox defaults ES10x MSS to OpenEUICC's most-compatible removable
  eUICC value of 63 rather than libeuicc's 120-byte default. This prevents
  dropped APDU segments during large Bound Profile Package writes.
