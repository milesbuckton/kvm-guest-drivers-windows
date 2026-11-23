/* ARM64X loader stub for the Venus Vulkan ICD (libvulkan_virtio.dll).
 *
 * Adapted from Kaede's vk_arm64x_stub.c for the viogpu3d package layout.
 *
 * Built twice (arm64 and arm64ec) and linked /machine:arm64x. Native ARM64
 * callers run the arm64 copy, ARM64EC and x64-emulated callers the arm64ec
 * copy, and each loads its payload from the directory this DLL lives in
 * (System32) and hands out the payload's entry points. The Vulkan loader
 * resolves the ICD entry points with GetProcAddress, so the stub exports
 * real functions rather than forwarders. Loaders using ICD interface v7 query
 * vk_icdEnumerateAdapterPhysicalDevices through vk_icdGetInstanceProcAddr,
 * which the payload answers.
 *
 *   arm64 view   -> libvulkan_virtio_arm64.dll   (Mesa arm64 build)
 *   arm64ec view -> libvulkan_virtio_arm64ec.dll (Mesa arm64ec build)
 */
#include <windows.h>
#include <stdint.h>

#ifdef _M_ARM64EC
#define PAYLOAD L"libvulkan_virtio_arm64ec.dll"
#else
#define PAYLOAD L"libvulkan_virtio_arm64.dll"
#endif

typedef int32_t (*PFN_negotiate)(uint32_t *);
typedef void *(*PFN_gipa)(void *, const char *);

static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
static PFN_negotiate p_negotiate;
static PFN_gipa p_gipa;
static PFN_gipa p_gpdpa;

static BOOL CALLBACK load_payload(PINIT_ONCE o, PVOID param, PVOID *ctx)
{
    (void)o;
    (void)param;
    (void)ctx;
    HMODULE self = NULL;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCWSTR)(void *)&load_payload,
                            &self))
    {
        return TRUE;
    }
    WCHAR path[MAX_PATH + 64];
    DWORD n = GetModuleFileNameW(self, path, MAX_PATH);
    if (!n || n >= MAX_PATH)
    {
        return TRUE;
    }
    while (n && path[n - 1] != L'\\' && path[n - 1] != L'/')
    {
        n--;
    }
    lstrcpyW(path + n, PAYLOAD);
    HMODULE m = LoadLibraryExW(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!m)
    {
        return TRUE;
    }
    p_negotiate = (PFN_negotiate)(void *)GetProcAddress(m, "vk_icdNegotiateLoaderICDInterfaceVersion");
    p_gipa = (PFN_gipa)(void *)GetProcAddress(m, "vk_icdGetInstanceProcAddr");
    p_gpdpa = (PFN_gipa)(void *)GetProcAddress(m, "vk_icdGetPhysicalDeviceProcAddr");
    return TRUE;
}

static void ensure_loaded(void)
{
    InitOnceExecuteOnce(&once, load_payload, NULL, NULL);
}

__declspec(dllexport) int32_t vk_icdNegotiateLoaderICDInterfaceVersion(uint32_t *version)
{
    ensure_loaded();
    /* VK_ERROR_INCOMPATIBLE_DRIVER when the payload is missing */
    return p_negotiate ? p_negotiate(version) : -9;
}

__declspec(dllexport) void *vk_icdGetInstanceProcAddr(void *instance, const char *name)
{
    ensure_loaded();
    return p_gipa ? p_gipa(instance, name) : NULL;
}

__declspec(dllexport) void *vk_icdGetPhysicalDeviceProcAddr(void *instance, const char *name)
{
    ensure_loaded();
    return p_gpdpa ? p_gpdpa(instance, name) : NULL;
}
