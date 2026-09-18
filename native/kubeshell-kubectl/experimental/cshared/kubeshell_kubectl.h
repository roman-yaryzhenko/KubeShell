#ifndef KUBESHELL_KUBECTL_H
#define KUBESHELL_KUBECTL_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef uint64_t ks_session_handle;
typedef uint64_t ks_operation_handle;

typedef struct ks_abi_probe_request {
    uint32_t struct_size;
    uint32_t requested_abi_major;
    uint32_t min_protocol;
    uint32_t max_protocol;
} ks_abi_probe_request;

typedef struct ks_abi_probe_response {
    uint32_t struct_size;
    uint32_t abi_major;
    uint32_t abi_minor;
    uint32_t min_protocol;
    uint32_t max_protocol;
    uint64_t feature_bits;
    uint8_t contract_hash[32];
    const char *build_version;
    const char *kubectl_version;
    const char *client_go_version;
} ks_abi_probe_response;

int32_t ks_abi_probe(ks_abi_probe_request *request, ks_abi_probe_response *response);
void ks_free(void *ptr);

#ifdef __cplusplus
}
#endif
#endif
