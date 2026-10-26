/* Local IPC fixture only: no sockets, windows, AirPlay, or user files. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *token = getenv("IPAD_WINDOW_EVENT_TOKEN");
    const char *mode = argc > 2 ? argv[2] : "";
    if (!token) return 2;
    if (!strcmp(mode, "IPC_RUNNING")) {
        printf("IPADWINDOW_EVENT %s BONJOUR_READY\n", token);
        fflush(stdout);
        for (;;) pause();
    }
    if (!strcmp(mode, "IPC_RNG_EXIT")) {
        printf("IPADWINDOW_EVENT %s RNG_FAILED\n", token);
    } else {
        printf("IPADWINDOW_EVENT %s BONJOUR_FAILED -65570\n", token);
    }
    fflush(stdout);
    _exit(23);
}
