#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>

namespace wvr::video {
struct NAL { const uint8_t* data; size_t size; unsigned type; };
// The stream API accepts complete Annex-B access units, including separate
// SPS/PPS packets. Reject truncation and unframed input instead of guessing.
inline bool splitAnnexB(const uint8_t* bytes, size_t size, std::vector<NAL>& out) {
    out.clear();
    if (!bytes || size < 4 || size > 8 * 1024 * 1024) return false;
    auto prefix = [&](size_t i) -> size_t {
        if (i + 3 <= size && bytes[i] == 0 && bytes[i+1] == 0) {
            if (bytes[i+2] == 1) return 3;
            if (i + 4 <= size && bytes[i+2] == 0 && bytes[i+3] == 1) return 4;
        }
        return 0;
    };
    size_t pos = 0;
    while (pos < size && !prefix(pos)) { if (bytes[pos++] != 0) return false; }
    if (pos == size) return false;
    while (pos < size) {
        size_t n = prefix(pos); if (!n) return false;
        size_t start = pos + n, end = start;
        while (end < size && !prefix(end)) ++end;
        size_t payloadEnd = end;
        while (payloadEnd > start && bytes[payloadEnd-1] == 0) --payloadEnd;
        if (payloadEnd == start || bytes[start] & 0x80) return false;
        unsigned type = bytes[start] & 31;
        if (!type || type > 23 || out.size() >= 1024) return false;
        out.push_back({bytes+start,payloadEnd-start,type}); pos = end;
    }
    return !out.empty();
}
inline void appendLengthPrefixed(std::vector<uint8_t>& bytes, const NAL& nal) {
    uint32_t n = static_cast<uint32_t>(nal.size);
    bytes.insert(bytes.end(),{uint8_t(n>>24),uint8_t(n>>16),uint8_t(n>>8),uint8_t(n)});
    bytes.insert(bytes.end(),nal.data,nal.data+nal.size);
}
}
