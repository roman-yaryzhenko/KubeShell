package main

/*
#include <stdint.h>
#include <stdlib.h>
#include "kubeshell_kubectl.h"
*/
import "C"

import (
	"unsafe"
)

const (
	abiMajor    = 1
	abiMinor    = 0
	minProtocol = 1
	maxProtocol = 1
)

var buildVersion = C.CString("kubeshell-native-bootstrap")
var kubectlVersion = C.CString("not-linked")
var clientGoVersion = C.CString("not-linked")

//export ks_abi_probe
func ks_abi_probe(request *C.ks_abi_probe_request, response *C.ks_abi_probe_response) C.int32_t {
	if request == nil || response == nil {
		return -1
	}
	if uint32(request.struct_size) < uint32(C.sizeof_ks_abi_probe_request) {
		return -2
	}
	if uint32(response.struct_size) < uint32(C.sizeof_ks_abi_probe_response) {
		return -3
	}
	if uint32(request.requested_abi_major) != abiMajor {
		return -4
	}
	if uint32(request.max_protocol) < minProtocol || uint32(request.min_protocol) > maxProtocol {
		return -5
	}

	response.abi_major = abiMajor
	response.abi_minor = abiMinor
	response.min_protocol = minProtocol
	response.max_protocol = maxProtocol
	response.feature_bits = 0
	response.build_version = buildVersion
	response.kubectl_version = kubectlVersion
	response.client_go_version = clientGoVersion
	return 0
}

//export ks_free
func ks_free(ptr unsafe.Pointer) {
	if ptr != nil {
		C.free(ptr)
	}
}

func main() {}
