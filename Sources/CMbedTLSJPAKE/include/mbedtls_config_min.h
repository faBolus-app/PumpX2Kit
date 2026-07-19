/*
 * Minimal mbedTLS config enabling ONLY what EC-JPAKE (secp256r1 / SHA-256) needs.
 * Keeps the compiled surface tiny (no PSA, SSL, TLS, entropy, DRBG) — we supply our own
 * RNG in the shim. Used via -DMBEDTLS_CONFIG_FILE for the CMbedTLS target.
 */
#ifndef MBEDTLS_CONFIG_MIN_H
#define MBEDTLS_CONFIG_MIN_H

/* Elliptic curve + EC-JPAKE */
#define MBEDTLS_ECP_C
#define MBEDTLS_ECJPAKE_C
#define MBEDTLS_ECP_DP_SECP256R1_ENABLED
#define MBEDTLS_ECP_NIST_OPTIM

/* Big numbers (required by ECP) */
#define MBEDTLS_BIGNUM_C

/* Hashing: message-digest layer + SHA-256/224 (EC-JPAKE uses SHA-256) */
#define MBEDTLS_MD_C
#define MBEDTLS_SHA256_C
#define MBEDTLS_SHA224_C

#endif /* MBEDTLS_CONFIG_MIN_H */
