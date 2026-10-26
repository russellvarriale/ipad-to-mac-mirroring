/* Native private video transport tests. No network listener or UI is started. */
#include "embedded_video.h"
#include <cassert>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>
#include <sys/socket.h>
#include <sys/wait.h>
#include <poll.h>
#include <unistd.h>

static const unsigned char unit[] = {0,0,0,1,0x65,0x42,0x24};
static int scenarios = 0;
static uint32_t be32(const unsigned char *data) {
    return (uint32_t(data[0]) << 24) | (uint32_t(data[1]) << 16) | (uint32_t(data[2]) << 8) | data[3];
}
static void status(pid_t child, int expected) {
    int result = 0;
    assert(waitpid(child, &result, 0) == child);
    assert(WIFEXITED(result) && WEXITSTATUS(result) == expected);
}
static std::vector<unsigned char> receive_all(int fd) {
    std::vector<unsigned char> data;
    unsigned char buffer[4093]; // Deliberately split header/payload boundaries.
    for (;;) {
        struct pollfd descriptor = {fd, POLLIN, 0};
        assert(poll(&descriptor, 1, 4000) > 0);
        ssize_t count = read(fd, buffer, sizeof(buffer));
        assert(count >= 0);
        if (!count) break;
        data.insert(data.end(), buffer, buffer + count);
        assert(data.size() <= IPAD_WINDOW_VIDEO_MAX_ACCESS_UNIT + 4096);
    }
    return data;
}
static size_t validate(const std::vector<unsigned char>& bytes) {
    size_t offset = 0, packets = 0;
    while (offset < bytes.size()) {
        assert(bytes.size() - offset >= 16);
        const unsigned char *header = bytes.data() + offset;
        assert(!memcmp(header, "IWV1", 4));
        uint32_t kind = be32(header + 4), length = be32(header + 8);
        assert(!be32(header + 12));
        assert((kind == 1 && length >= 5) || (kind == 2 && length == 0));
        assert(length <= IPAD_WINDOW_VIDEO_MAX_ACCESS_UNIT && bytes.size() - offset - 16 >= length);
        if (kind == 1) assert(!memcmp(header + 16, unit, 4));
        offset += 16 + length;
        ++packets;
    }
    return packets;
}
static pid_t launch(int endpoints[2], int mode) {
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, endpoints) == 0);
    pid_t child = fork(); assert(child >= 0);
    if (!child) {
        close(endpoints[0]);
        assert(dup2(endpoints[1], STDIN_FILENO) == STDIN_FILENO);
        close(endpoints[1]);
        assert(ipad_window_video_initialize() == 0);
        if (mode == 0) {
            ipad_window_video_reset(); ipad_window_video_access_unit(unit, sizeof(unit));
        } else if (mode == 1) {
            std::thread first([] { for (int i=0; i<8; ++i) { ipad_window_video_reset(); ipad_window_video_access_unit(unit,sizeof(unit)); }});
            std::thread second([] { for (int i=0; i<8; ++i) { ipad_window_video_reset(); ipad_window_video_access_unit(unit,sizeof(unit)); }});
            first.join(); second.join();
        } else if (mode == 2) {
            ipad_window_video_access_unit(nullptr, 7);
        } else if (mode == 3) {
            ipad_window_video_access_unit(unit, 4);
        } else if (mode == 4) {
            ipad_window_video_access_unit(unit, size_t(IPAD_WINDOW_VIDEO_MAX_ACCESS_UNIT) + 1);
        } else if (mode == 5) {
            unsigned char bad[] = {0,0,0,2,0x65}; ipad_window_video_access_unit(bad,sizeof(bad));
        } else if (mode == 6 || mode == 7) {
            std::vector<unsigned char> maximum(IPAD_WINDOW_VIDEO_MAX_ACCESS_UNIT, 0x42);
            memcpy(maximum.data(), unit, sizeof(unit));
            int small = 4096; assert(!setsockopt(0,SOL_SOCKET,SO_SNDBUF,&small,sizeof(small)));
            ipad_window_video_access_unit(maximum.data(),maximum.size());
        } else if (mode == 8) {
            ipad_window_video_reset(); usleep(200000); ipad_window_video_access_unit(unit,sizeof(unit));
        } else if (mode == 9 || mode == 10) {
            ipad_window_video_reset(); usleep(200000); assert(!ipad_window_video_peer_alive());
        }
        _exit(0);
    }
    close(endpoints[1]);
    return child;
}
static void rejected_descriptor(int type) {
    int descriptors[2];
    if (type == 0) assert(pipe(descriptors) == 0);
    else assert(socketpair(AF_UNIX, SOCK_DGRAM, 0, descriptors) == 0);
    pid_t child = fork(); assert(child >= 0);
    if (!child) {
        close(descriptors[0]); assert(dup2(descriptors[1],0)==0); close(descriptors[1]);
        assert(ipad_window_video_initialize() < 0); _exit(0);
    }
    close(descriptors[0]); close(descriptors[1]); status(child,0); ++scenarios;
}
int main() {
    int endpoints[2];
    pid_t child = launch(endpoints,0);
    auto bytes = receive_all(endpoints[0]); close(endpoints[0]); status(child,0);
    assert(validate(bytes)==2 && be32(bytes.data()+4)==2 && be32(bytes.data()+20)==1); ++scenarios;
    child=launch(endpoints,1); bytes=receive_all(endpoints[0]); close(endpoints[0]); status(child,0);
    assert(validate(bytes)==32); ++scenarios;
    for (int mode=2;mode<=5;++mode) {
        child=launch(endpoints,mode); bytes=receive_all(endpoints[0]); close(endpoints[0]); status(child,1);
        assert(bytes.empty()); ++scenarios;
    }
    child=launch(endpoints,6); bytes=receive_all(endpoints[0]); close(endpoints[0]); status(child,0);
    assert(validate(bytes)==1 && bytes.size()==size_t(IPAD_WINDOW_VIDEO_MAX_ACCESS_UNIT)+16); ++scenarios;
    const auto start=std::chrono::steady_clock::now();
    child=launch(endpoints,7); status(child,1); close(endpoints[0]);
    double elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
    assert(elapsed>=1.5 && elapsed<4); ++scenarios;
    child=launch(endpoints,8); unsigned char reset[16]; assert(read(endpoints[0],reset,sizeof(reset))==16);
    close(endpoints[0]); status(child,1); ++scenarios; // EPIPE is not SIGPIPE.
    child=launch(endpoints,9); assert(read(endpoints[0],reset,sizeof(reset))==16);
    close(endpoints[0]); status(child,0); ++scenarios;
    child=launch(endpoints,10); assert(read(endpoints[0],reset,sizeof(reset))==16);
    assert(write(endpoints[0],"x",1)==1); status(child,0); close(endpoints[0]); ++scenarios;
    rejected_descriptor(0); rejected_descriptor(1);
    // A socketpair created by the grandparent is not this child's parent capability.
    assert(socketpair(AF_UNIX,SOCK_STREAM,0,endpoints)==0);
    child=fork(); assert(child>=0);
    if (!child) {
        pid_t grandchild=fork(); assert(grandchild>=0);
        if (!grandchild) {
            close(endpoints[0]); assert(dup2(endpoints[1],0)==0); close(endpoints[1]);
            assert(ipad_window_video_initialize()<0); _exit(0);
        }
        close(endpoints[0]); close(endpoints[1]); status(grandchild,0); _exit(0);
    }
    close(endpoints[0]); close(endpoints[1]); status(child,0); ++scenarios;
    printf("PASS: %d native embedded-video transport scenarios (ASan + UBSan)\n",scenarios);
}
