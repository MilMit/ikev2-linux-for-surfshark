#define UNICODE
#define _UNICODE
#include <windows.h>
#include <fwpmu.h>
#include <ws2tcpip.h>
#include <stdint.h>
#include <stdio.h>

#pragma comment(lib, "fwpuclnt.lib")
#pragma comment(lib, "rpcrt4.lib")
#pragma comment(lib, "ws2_32.lib")

static const GUID MILMIT_SUBLAYER = {0xd5686c0f,0x72f6,0x4af1,{0x9c,0x86,0x9f,0x84,0x49,0x53,0x32,0x20}};
static const GUID FILTER_BLOCK_V4 = {0x79d3fb11,0x4c8e,0x4f0f,{0xab,0x32,0x2c,0x58,0x3f,0xc1,0x31,0x41}};
static const GUID FILTER_BLOCK_V6 = {0x74944d86,0x6922,0x4850,{0xb5,0xe1,0xd5,0xf6,0xeb,0x96,0xbc,0xf6}};
static const GUID FILTER_ALLOW_V4 = {0xd3e99515,0x0554,0x4536,{0xac,0x2d,0x29,0x95,0x1c,0x5a,0xbc,0x55}};
static const GUID FILTER_ALLOW_V6 = {0x7ea0ccb4,0x3889,0x4f2b,{0x9d,0x98,0xe0,0x85,0xda,0x75,0xfc,0xeb}};

static DWORD open_engine(HANDLE *engine) {
    return FwpmEngineOpen0(NULL, RPC_C_AUTHN_WINNT, NULL, NULL, engine);
}

static void delete_filter(HANDLE engine, const GUID *key) {
    FwpmFilterDeleteByKey0(engine, key);
}

static DWORD ensure_sublayer(HANDLE engine) {
    FWPM_SUBLAYER0 s;
    ZeroMemory(&s, sizeof(s));
    s.subLayerKey = MILMIT_SUBLAYER;
    s.displayData.name = L"MilMit VPN Kill Switch";
    s.displayData.description = L"MilMit VPN WFP kill-switch policy";
    s.flags = FWPM_SUBLAYER_FLAG_PERSISTENT;
    s.weight = 0x7000;
    DWORD rc = FwpmSubLayerAdd0(engine, &s, NULL);
    if (rc == FWP_E_ALREADY_EXISTS) return ERROR_SUCCESS;
    return rc;
}

static DWORD add_block(HANDLE engine, const GUID *key, const GUID *layer, UINT32 ifindex) {
    FWPM_FILTER_CONDITION0 cond;
    ZeroMemory(&cond, sizeof(cond));
    cond.fieldKey = FWPM_CONDITION_INTERFACE_INDEX;
    cond.matchType = FWP_MATCH_EQUAL;
    cond.conditionValue.type = FWP_UINT32;
    cond.conditionValue.uint32 = ifindex;

    FWPM_FILTER0 f;
    ZeroMemory(&f, sizeof(f));
    f.filterKey = *key;
    f.displayData.name = L"MilMit block physical uplink";
    f.layerKey = *layer;
    f.subLayerKey = MILMIT_SUBLAYER;
    f.flags = FWPM_FILTER_FLAG_PERSISTENT;
    f.action.type = FWP_ACTION_BLOCK;
    f.weight.type = FWP_UINT8;
    f.weight.uint8 = 10;
    f.numFilterConditions = 1;
    f.filterCondition = &cond;
    return FwpmFilterAdd0(engine, &f, NULL, NULL);
}

static DWORD add_allow_v4(HANDLE engine, UINT32 ifindex, const wchar_t *endpoint) {
    IN_ADDR addr;
    if (InetPtonW(AF_INET, endpoint, &addr) != 1) return ERROR_INVALID_PARAMETER;
    FWPM_FILTER_CONDITION0 conds[2];
    ZeroMemory(conds, sizeof(conds));
    conds[0].fieldKey = FWPM_CONDITION_INTERFACE_INDEX;
    conds[0].matchType = FWP_MATCH_EQUAL;
    conds[0].conditionValue.type = FWP_UINT32;
    conds[0].conditionValue.uint32 = ifindex;
    conds[1].fieldKey = FWPM_CONDITION_IP_REMOTE_ADDRESS;
    conds[1].matchType = FWP_MATCH_EQUAL;
    conds[1].conditionValue.type = FWP_UINT32;
    conds[1].conditionValue.uint32 = ntohl(addr.S_un.S_addr);

    FWPM_FILTER0 f;
    ZeroMemory(&f, sizeof(f));
    f.filterKey = FILTER_ALLOW_V4;
    f.displayData.name = L"MilMit allow VPN endpoint IPv4";
    f.layerKey = FWPM_LAYER_ALE_AUTH_CONNECT_V4;
    f.subLayerKey = MILMIT_SUBLAYER;
    f.flags = FWPM_FILTER_FLAG_PERSISTENT;
    f.action.type = FWP_ACTION_PERMIT;
    f.weight.type = FWP_UINT8;
    f.weight.uint8 = 15;
    f.numFilterConditions = 2;
    f.filterCondition = conds;
    return FwpmFilterAdd0(engine, &f, NULL, NULL);
}

static DWORD add_allow_v6(HANDLE engine, UINT32 ifindex, const wchar_t *endpoint) {
    IN6_ADDR addr;
    if (InetPtonW(AF_INET6, endpoint, &addr) != 1) return ERROR_INVALID_PARAMETER;
    FWP_BYTE_ARRAY16 bytes;
    CopyMemory(bytes.byteArray16, &addr, 16);
    FWPM_FILTER_CONDITION0 conds[2];
    ZeroMemory(conds, sizeof(conds));
    conds[0].fieldKey = FWPM_CONDITION_INTERFACE_INDEX;
    conds[0].matchType = FWP_MATCH_EQUAL;
    conds[0].conditionValue.type = FWP_UINT32;
    conds[0].conditionValue.uint32 = ifindex;
    conds[1].fieldKey = FWPM_CONDITION_IP_REMOTE_ADDRESS;
    conds[1].matchType = FWP_MATCH_EQUAL;
    conds[1].conditionValue.type = FWP_BYTE_ARRAY16_TYPE;
    conds[1].conditionValue.byteArray16 = &bytes;

    FWPM_FILTER0 f;
    ZeroMemory(&f, sizeof(f));
    f.filterKey = FILTER_ALLOW_V6;
    f.displayData.name = L"MilMit allow VPN endpoint IPv6";
    f.layerKey = FWPM_LAYER_ALE_AUTH_CONNECT_V6;
    f.subLayerKey = MILMIT_SUBLAYER;
    f.flags = FWPM_FILTER_FLAG_PERSISTENT;
    f.action.type = FWP_ACTION_PERMIT;
    f.weight.type = FWP_UINT8;
    f.weight.uint8 = 15;
    f.numFilterConditions = 2;
    f.filterCondition = conds;
    return FwpmFilterAdd0(engine, &f, NULL, NULL);
}

static DWORD disable_all(HANDLE engine) {
    delete_filter(engine, &FILTER_ALLOW_V4);
    delete_filter(engine, &FILTER_ALLOW_V6);
    delete_filter(engine, &FILTER_BLOCK_V4);
    delete_filter(engine, &FILTER_BLOCK_V6);
    FwpmSubLayerDeleteByKey0(engine, &MILMIT_SUBLAYER);
    return ERROR_SUCCESS;
}

static DWORD enable_policy(HANDLE engine, UINT32 ifindex, const wchar_t *endpoint) {
    DWORD rc = ensure_sublayer(engine);
    if (rc != ERROR_SUCCESS) return rc;
    disable_all(engine);
    rc = ensure_sublayer(engine);
    if (rc != ERROR_SUCCESS) return rc;

    IN_ADDR v4;
    IN6_ADDR v6;
    if (InetPtonW(AF_INET, endpoint, &v4) == 1) {
        rc = add_allow_v4(engine, ifindex, endpoint);
        if (rc != ERROR_SUCCESS) return rc;
    } else if (InetPtonW(AF_INET6, endpoint, &v6) == 1) {
        rc = add_allow_v6(engine, ifindex, endpoint);
        if (rc != ERROR_SUCCESS) return rc;
    } else {
        return ERROR_INVALID_PARAMETER;
    }

    rc = add_block(engine, &FILTER_BLOCK_V4, &FWPM_LAYER_ALE_AUTH_CONNECT_V4, ifindex);
    if (rc != ERROR_SUCCESS) return rc;
    rc = add_block(engine, &FILTER_BLOCK_V6, &FWPM_LAYER_ALE_AUTH_CONNECT_V6, ifindex);
    return rc;
}

int wmain(int argc, wchar_t **argv) {
    if (argc < 2) {
        fwprintf(stderr, L"usage: wfp-helper enable <interface-index> <vpn-endpoint-ip> | disable\n");
        return 2;
    }
    HANDLE engine = NULL;
    DWORD rc = open_engine(&engine);
    if (rc != ERROR_SUCCESS) {
        fwprintf(stderr, L"FwpmEngineOpen0 failed: %lu\n", rc);
        return (int)rc;
    }
    if (_wcsicmp(argv[1], L"disable") == 0) {
        rc = disable_all(engine);
    } else if (_wcsicmp(argv[1], L"enable") == 0 && argc == 4) {
        UINT32 ifindex = (UINT32)_wcstoui64(argv[2], NULL, 10);
        if (!ifindex) rc = ERROR_INVALID_PARAMETER;
        else rc = enable_policy(engine, ifindex, argv[3]);
    } else {
        rc = ERROR_INVALID_PARAMETER;
    }
    FwpmEngineClose0(engine);
    if (rc != ERROR_SUCCESS) {
        fwprintf(stderr, L"WFP operation failed: %lu\n", rc);
        return (int)rc;
    }
    wprintf(L"ok\n");
    return 0;
}
