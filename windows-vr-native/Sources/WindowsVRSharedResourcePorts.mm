#include "WindowsVRSharedResourcePorts.h"
#include <mach/mach.h>
#include <dlfcn.h>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <new>
#include <string>
#include <unordered_map>

namespace {
// Matches Winemetal transport ABI 1, slots 121/122. The existing mobile
// handlers return STATUS_NOT_SUPPORTED; macOS's bootstrap server is not used.
struct PortRequest {
    char name[128];
    uint32_t port;
    uint32_t reserved;
};
static_assert(sizeof(PortRequest) == 136 && offsetof(PortRequest, port) == 128);
constexpr int32_t success = 0;
constexpr int32_t invalidParameter = int32_t(0xc000000du);
constexpr int32_t notFound = int32_t(0xc0000034u);
constexpr int32_t collision = int32_t(0xc0000035u);
constexpr int32_t noResources = int32_t(0xc000009au);
constexpr int32_t unsuccessful = int32_t(0xc0000001u);
constexpr size_t maximumNames = 4096;

struct PortRegistry {
    std::mutex mutex;
    std::unordered_map<std::string, mach_port_t> ports;
    unsigned registers = 0, lookups = 0;

    void clear() {
        std::lock_guard<std::mutex> lock(mutex);
        for (const auto& entry : ports) mach_port_deallocate(mach_task_self(), entry.second);
        ports.clear();
    }
    ~PortRegistry() { clear(); }
};

PortRegistry& registry() {
    static PortRegistry value;
    return value;
}

bool validName(const PortRequest* request) {
    return request && request->name[0] && std::memchr(request->name, 0, sizeof(request->name));
}

int32_t registerPort(void* opaque) {
    const auto* request = static_cast<const PortRequest*>(opaque);
    if (!validName(request) || !MACH_PORT_VALID(request->port)) return invalidParameter;
    try {
        const std::string name(request->name);
        auto& state = registry();
        std::lock_guard<std::mutex> lock(state.mutex);
        mach_port_type_t type = 0;
        if (mach_port_type(mach_task_self(), request->port, &type) != KERN_SUCCESS ||
            !(type & MACH_PORT_TYPE_SEND)) return invalidParameter;
        auto found = state.ports.find(name);
        if (found != state.ports.end()) return found->second == request->port ? success : collision;
        if (state.ports.size() >= maximumNames) return noResources;
        if (mach_port_mod_refs(mach_task_self(), request->port, MACH_PORT_RIGHT_SEND, 1) != KERN_SUCCESS)
            return unsuccessful;
        try {
            state.ports.emplace(name, request->port);
        } catch (...) {
            mach_port_deallocate(mach_task_self(), request->port);
            throw;
        }
        if (++state.registers <= 4)
            std::fprintf(stderr, "[shared-resource] app-local port registered; names=%zu\n", state.ports.size());
        return success;
    } catch (const std::bad_alloc&) {
        return noResources;
    }
}

int32_t lookupPort(void* opaque) {
    auto* request = static_cast<PortRequest*>(opaque);
    if (request) request->port = MACH_PORT_NULL;
    if (!validName(request)) return invalidParameter;
    try {
        auto& state = registry();
        std::lock_guard<std::mutex> lock(state.mutex);
        auto found = state.ports.find(std::string(request->name));
        if (found == state.ports.end()) return notFound;
        if (mach_port_mod_refs(mach_task_self(), found->second, MACH_PORT_RIGHT_SEND, 1) != KERN_SUCCESS) {
            // A destroyed receive right turns the retained send right into a
            // dead name. Remove it without returning a fabricated live handle.
            mach_port_deallocate(mach_task_self(), found->second);
            state.ports.erase(found);
            return notFound;
        }
        request->port = found->second;
        if (++state.lookups <= 4)
            std::fprintf(stderr, "[shared-resource] app-local port lookup retained a send right\n");
        return success;
    } catch (const std::bad_alloc&) {
        return noResources;
    }
}

bool writableDispatchSlots(void** table) {
    if (!table) return false;
    vm_address_t address = reinterpret_cast<vm_address_t>(table + 121);
    const vm_address_t end = reinterpret_cast<vm_address_t>(table + 123);
    const vm_address_t requested = address;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info{};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    const auto result = vm_region_64(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
        reinterpret_cast<vm_region_info_t>(&info), &count, &object);
    if (MACH_PORT_VALID(object)) mach_port_deallocate(mach_task_self(), object);
    return result == KERN_SUCCESS && address <= requested && end >= requested && end - address <= size &&
        (info.protection & VM_PROT_WRITE) && !(info.protection & VM_PROT_EXECUTE);
}

int installTable(void** table, size_t count, unsigned abi) {
    if (count != 149 || abi != 1 || !writableDispatchSlots(table) || !table[121] || !table[122]) return 0;
    table[121] = reinterpret_cast<void*>(registerPort);
    table[122] = reinterpret_cast<void*>(lookupPort);
    return 1;
}
} // namespace

extern "C" int wvr_shared_resource_ports_install_v1(void) {
    static std::mutex installMutex;
    static bool installed = false;
    std::lock_guard<std::mutex> lock(installMutex);
    if (installed) return 1;
    auto* table = static_cast<void**>(dlsym(RTLD_DEFAULT, "dxmt_winemetal_unix_call_funcs"));
    auto count = reinterpret_cast<size_t (*)()>(dlsym(RTLD_DEFAULT, "wvr_dxmt_d3d12_unix_call_count_v1"));
    auto abi = reinterpret_cast<unsigned (*)()>(dlsym(RTLD_DEFAULT, "wvr_dxmt_d3d12_transport_abi_v1"));
    if (!count || !abi || !installTable(table, count(), abi())) return 0;
    installed = true;
    return 1;
}
