#include "CVoWiFiCrypto.h"
#include <CommonCrypto/CommonCryptor.h>
#include <string.h>

static int vowifi_aes_cbc(
    CCOperation operation,
    const uint8_t *key, size_t key_length,
    const uint8_t iv[16],
    const uint8_t *input, size_t input_length,
    uint8_t *output, size_t output_capacity,
    size_t *output_length
) {
    if (!key || !iv || !input || !output || !output_length) return kCCParamError;
    if (input_length == 0 || input_length % kCCBlockSizeAES128 != 0) return kCCAlignmentError;
    return CCCrypt(
        operation, kCCAlgorithmAES, 0,
        key, key_length, iv,
        input, input_length,
        output, output_capacity, output_length
    );
}

int vowifi_aes_cbc_encrypt(
    const uint8_t *key, size_t key_length,
    const uint8_t iv[16],
    const uint8_t *input, size_t input_length,
    uint8_t *output, size_t output_capacity,
    size_t *output_length
) {
    return vowifi_aes_cbc(kCCEncrypt, key, key_length, iv, input, input_length,
                          output, output_capacity, output_length);
}

int vowifi_aes_cbc_decrypt(
    const uint8_t *key, size_t key_length,
    const uint8_t iv[16],
    const uint8_t *input, size_t input_length,
    uint8_t *output, size_t output_capacity,
    size_t *output_length
) {
    return vowifi_aes_cbc(kCCDecrypt, key, key_length, iv, input, input_length,
                          output, output_capacity, output_length);
}

#define MODP14_LIMBS 64

typedef struct {
    uint32_t limb[MODP14_LIMBS];
} modp14_number;

/* RFC 3526 section 3 prime, stored as little-endian 32-bit limbs. */
static const modp14_number modp14_prime = {{
    0xFFFFFFFF, 0xFFFFFFFF, 0x8AACAA68, 0x15728E5A,
    0x98FA0510, 0x15D22618, 0xEA956AE5, 0x3995497C,
    0x95581718, 0xDE2BCBF6, 0x6F4C52C9, 0xB5C55DF0,
    0xEC07A28F, 0x9B2783A2, 0x180E8603, 0xE39E772C,
    0x2E36CE3B, 0x32905E46, 0xCA18217C, 0xF1746C08,
    0x4ABC9804, 0x670C354E, 0x7096966D, 0x9ED52907,
    0x208552BB, 0x1C62F356, 0xDCA3AD96, 0x83655D23,
    0xFD24CF5F, 0x69163FA8, 0x1C55D39A, 0x98DA4836,
    0xA163BF05, 0xC2007CB8, 0xECE45B3D, 0x49286651,
    0x7C4B1FE6, 0xAE9F2411, 0x5A899FA5, 0xEE386BFB,
    0xF406B7ED, 0x0BFF5CB6, 0xA637ED6B, 0xF44C42E9,
    0x625E7EC6, 0xE485B576, 0x6D51C245, 0x4FE1356D,
    0xF25F1437, 0x302B0A6D, 0xCD3A431B, 0xEF9519B3,
    0x8E3404DD, 0x514A0879, 0x3B139B22, 0x020BBEA6,
    0x8A67CC74, 0x29024E08, 0x80DC1CD1, 0xC4C6628B,
    0x2168C234, 0xC90FDAA2, 0xFFFFFFFF, 0xFFFFFFFF
}};

static int modp14_compare(const modp14_number *a, const modp14_number *b) {
    for (int i = MODP14_LIMBS - 1; i >= 0; --i) {
        if (a->limb[i] < b->limb[i]) return -1;
        if (a->limb[i] > b->limb[i]) return 1;
    }
    return 0;
}

static void modp14_add(
    modp14_number *output,
    const modp14_number *a,
    const modp14_number *b
) {
    uint32_t extended[MODP14_LIMBS + 1] = {0};
    uint64_t carry = 0;
    for (size_t i = 0; i < MODP14_LIMBS; ++i) {
        uint64_t sum = (uint64_t)a->limb[i] + b->limb[i] + carry;
        extended[i] = (uint32_t)sum;
        carry = sum >> 32;
    }
    extended[MODP14_LIMBS] = (uint32_t)carry;
    modp14_number low;
    memcpy(low.limb, extended, sizeof(low.limb));
    if (extended[MODP14_LIMBS] || modp14_compare(&low, &modp14_prime) >= 0) {
        uint64_t borrow = 0;
        for (size_t i = 0; i < MODP14_LIMBS; ++i) {
            uint64_t subtrahend = (uint64_t)modp14_prime.limb[i] + borrow;
            uint64_t value = extended[i];
            extended[i] = (uint32_t)(value - subtrahend);
            borrow = value < subtrahend;
        }
        extended[MODP14_LIMBS] -= (uint32_t)borrow;
    }
    memcpy(output->limb, extended, sizeof(output->limb));
}

static void modp14_multiply(
    modp14_number *output,
    const modp14_number *a,
    const modp14_number *b
) {
    modp14_number result = {{0}};
    modp14_number addend = *a;
    for (size_t bit = 0; bit < MODP14_LIMBS * 32; ++bit) {
        if ((b->limb[bit / 32] >> (bit % 32)) & 1U) {
            modp14_add(&result, &result, &addend);
        }
        modp14_add(&addend, &addend, &addend);
    }
    *output = result;
}

static void modp14_power(
    modp14_number *output,
    const modp14_number *base_value,
    const uint8_t private_key[32]
) {
    modp14_number result = {{1}};
    modp14_number base = *base_value;
    for (int byte = 31; byte >= 0; --byte) {
        for (unsigned bit = 0; bit < 8; ++bit) {
            if ((private_key[byte] >> bit) & 1U) {
                modp14_multiply(&result, &result, &base);
            }
            modp14_multiply(&base, &base, &base);
        }
    }
    *output = result;
}

static void modp14_from_big_endian(modp14_number *output, const uint8_t bytes[256]) {
    for (size_t i = 0; i < MODP14_LIMBS; ++i) {
        size_t offset = 256 - ((i + 1) * 4);
        output->limb[i] = ((uint32_t)bytes[offset] << 24)
            | ((uint32_t)bytes[offset + 1] << 16)
            | ((uint32_t)bytes[offset + 2] << 8)
            | (uint32_t)bytes[offset + 3];
    }
}

static void modp14_to_big_endian(uint8_t bytes[256], const modp14_number *input) {
    for (size_t i = 0; i < MODP14_LIMBS; ++i) {
        size_t offset = 256 - ((i + 1) * 4);
        uint32_t value = input->limb[i];
        bytes[offset] = (uint8_t)(value >> 24);
        bytes[offset + 1] = (uint8_t)(value >> 16);
        bytes[offset + 2] = (uint8_t)(value >> 8);
        bytes[offset + 3] = (uint8_t)value;
    }
}

int vowifi_modp14_public_key(
    const uint8_t private_key[32],
    uint8_t public_key[256]
) {
    if (!private_key || !public_key) return -1;
    modp14_number generator = {{2}};
    modp14_number result;
    modp14_power(&result, &generator, private_key);
    modp14_to_big_endian(public_key, &result);
    memset(&result, 0, sizeof(result));
    return 0;
}

int vowifi_modp14_shared_secret(
    const uint8_t private_key[32],
    const uint8_t peer_public_key[256],
    uint8_t shared_secret[256]
) {
    if (!private_key || !peer_public_key || !shared_secret) return -1;
    modp14_number peer;
    modp14_from_big_endian(&peer, peer_public_key);
    modp14_number one = {{1}};
    modp14_number maximum = modp14_prime;
    maximum.limb[0] -= 1;
    if (modp14_compare(&peer, &one) <= 0 || modp14_compare(&peer, &maximum) >= 0) {
        return -1;
    }
    modp14_number result;
    modp14_power(&result, &peer, private_key);
    modp14_to_big_endian(shared_secret, &result);
    memset(&result, 0, sizeof(result));
    memset(&peer, 0, sizeof(peer));
    return 0;
}
