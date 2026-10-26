/* Private, bounded H264 transport to the iPad to Mac Mirroring parent process.
 * GPL-3.0-or-later, under the terms of this UxPlay integration. */
#include "embedded_video.h"
#include <chrono>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace {
constexpr int video_fd = STDIN_FILENO;
constexpr int packet_deadline_ms = 2000;
std::mutex writer_mutex;
bool initialized = false; // Initialized before any callbacks/watchdog are started.

[[noreturn]] void fail_transport() {
    // Do not block on a log pipe while trying to close network listeners.
    _exit(1);
}

void write_be32(unsigned char *destination, uint32_t value) {
    destination[0] = static_cast<unsigned char>(value >> 24);
    destination[1] = static_cast<unsigned char>(value >> 16);
    destination[2] = static_cast<unsigned char>(value >> 8);
    destination[3] = static_cast<unsigned char>(value);
}

void send_bytes(const unsigned char *data, size_t length,
                const std::chrono::steady_clock::time_point deadline) {
    while (length) {
        auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline - std::chrono::steady_clock::now()).count();
        if (remaining <= 0) fail_transport();
        struct pollfd descriptor = { video_fd, POLLOUT, 0 };
        int ready = poll(&descriptor, 1, static_cast<int>(remaining));
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0 || (descriptor.revents & (POLLERR | POLLHUP | POLLNVAL))) fail_transport();
        if (!(descriptor.revents & POLLOUT)) continue;
        ssize_t sent = send(video_fd, data, length, MSG_NOSIGNAL);
        if (sent < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (sent <= 0) fail_transport();
        data += sent;
        length -= static_cast<size_t>(sent);
    }
}

void send_packet(uint32_t kind, const unsigned char *data, size_t length) {
    std::lock_guard<std::mutex> guard(writer_mutex);
    if (!initialized || length > IPAD_WINDOW_VIDEO_MAX_ACCESS_UNIT) fail_transport();
    unsigned char header[16] = { 'I', 'W', 'V', '1' };
    write_be32(header + 4, kind);
    write_be32(header + 8, static_cast<uint32_t>(length));
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(packet_deadline_ms);
    send_bytes(header, sizeof(header), deadline);
    if (length) send_bytes(data, length, deadline);
}
}

int ipad_window_video_initialize(void) {
    if (initialized) return -1;
    int type = 0;
    socklen_t type_length = sizeof(type);
    struct sockaddr_storage address = {};
    socklen_t address_length = sizeof(address);
    if (getsockopt(video_fd, SOL_SOCKET, SO_TYPE, &type, &type_length) || type != SOCK_STREAM ||
        getsockname(video_fd, reinterpret_cast<struct sockaddr *>(&address), &address_length) ||
        address.ss_family != AF_UNIX) return -1;
#ifdef __APPLE__
    uid_t peer_uid = 0;
    gid_t peer_gid = 0;
    if (getpeereid(video_fd, &peer_uid, &peer_gid) || peer_uid != geteuid()) return -1;
    pid_t peer_pid = 0;
    socklen_t pid_length = sizeof(peer_pid);
    if (getsockopt(video_fd, SOL_LOCAL, LOCAL_PEERPID, &peer_pid, &pid_length) == 0) {
        if (pid_length != sizeof(peer_pid) || peer_pid != getppid()) return -1;
    } else if (errno != ENOPROTOOPT && errno != ENOTSUP && errno != EINVAL) {
        return -1;
    }
    int no_sigpipe = 1;
    if (setsockopt(video_fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe))) return -1;
#else
    return -1; // This bundled transport contract is macOS-only.
#endif
    int flags = fcntl(video_fd, F_GETFL);
    int descriptor_flags = fcntl(video_fd, F_GETFD);
    if (flags < 0 || descriptor_flags < 0 ||
        fcntl(video_fd, F_SETFL, flags | O_NONBLOCK) < 0 ||
        fcntl(video_fd, F_SETFD, descriptor_flags | FD_CLOEXEC) < 0) return -1;
    initialized = true;
    return 0;
}

int ipad_window_video_peer_alive(void) {
    if (!initialized) return 0;
    struct pollfd descriptor = { video_fd, POLLIN, 0 };
    int ready = poll(&descriptor, 1, 0);
    if (ready < 0) return errno == EINTR;
    if (descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) return 0;
    if (descriptor.revents & POLLIN) {
        unsigned char byte;
        ssize_t count = recv(video_fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
        // This channel is child-to-parent only; incoming data is not a command.
        return count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR);
    }
    return 1;
}

void ipad_window_video_reset(void) {
    send_packet(2, nullptr, 0);
}

void ipad_window_video_access_unit(const unsigned char *data, size_t length) {
    static const unsigned char start_code[] = {0, 0, 0, 1};
    if (!data || length < 5 || length > IPAD_WINDOW_VIDEO_MAX_ACCESS_UNIT ||
        memcmp(data, start_code, sizeof(start_code)) || (data[4] & 0x80)) fail_transport();
    send_packet(1, data, length);
}
