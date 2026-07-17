#ifndef C_VOWIFI_CRYPTO_H
#define C_VOWIFI_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

int vowifi_aes_cbc_encrypt(
    const uint8_t *key, size_t key_length,
    const uint8_t iv[16],
    const uint8_t *input, size_t input_length,
    uint8_t *output, size_t output_capacity,
    size_t *output_length
);

int vowifi_aes_cbc_decrypt(
    const uint8_t *key, size_t key_length,
    const uint8_t iv[16],
    const uint8_t *input, size_t input_length,
    uint8_t *output, size_t output_capacity,
    size_t *output_length
);

/// RFC 3526 MODP group 14 (2048-bit) using a 256-bit private exponent.
/// Buffers are big-endian. Returns 0 on success and -1 for invalid input.
int vowifi_modp14_public_key(
    const uint8_t private_key[32],
    uint8_t public_key[256]
);

int vowifi_modp14_shared_secret(
    const uint8_t private_key[32],
    const uint8_t peer_public_key[256],
    uint8_t shared_secret[256]
);

#endif
