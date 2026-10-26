/* Private, bounded H264 transport to the iPad to Mac Mirroring parent process.
 * GPL-3.0-or-later, under the terms of this UxPlay integration. */
#ifndef IPAD_WINDOW_EMBEDDED_VIDEO_H
#define IPAD_WINDOW_EMBEDDED_VIDEO_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
#define IPAD_WINDOW_VIDEO_MAX_ACCESS_UNIT (16u * 1024u * 1024u)
int ipad_window_video_initialize(void);
int ipad_window_video_peer_alive(void);
void ipad_window_video_reset(void);
void ipad_window_video_access_unit(const unsigned char *data, size_t length);
#ifdef __cplusplus
}
#endif
#endif
