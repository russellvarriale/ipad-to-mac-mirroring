/* iPad to Mac Mirroring presentation for the pinned GStreamer Cocoa video window.
 * Licensed under the same GPL-3.0-or-later terms as this UxPlay integration. */
#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>

static id main_window_observer;
static id key_window_observer;
static id application_active_observer;

static void brand_video_window(NSWindow *window)
{
    /* GStreamer 1.28.8 creates this normal, shareable window and then changes
     * NSApp to Regular. Observe its later main/key transition, after creation,
     * and change presentation only. No private selectors or GL access. */
    Class video_window_class = NSClassFromString(@"GstGLNSWindow");
    if (!video_window_class || ![window isKindOfClass:video_window_class]) return;
    NSString *title = @"iPad to Mac Mirroring \u2014 Wireless";
    if (![window.title isEqualToString:title]) window.title = title;
    if (NSApp.activationPolicy != NSApplicationActivationPolicyAccessory)
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

static void video_window_became_active(NSNotification *notification)
{
    if (![notification.object isKindOfClass:[NSWindow class]]) return;
    NSWindow *window = notification.object;
    if ([NSThread isMainThread]) {
        brand_video_window(window);
    } else {
        /* The retained window survives until this block runs; closing it in the
         * meantime does not make it visible again or alter its rendering. */
        dispatch_async(dispatch_get_main_queue(), ^{ brand_video_window(window); });
    }
}

void ipad_window_macos_presentation_refresh(void)
{
    /* Paused GL pipeline setup can create a hidden video window and force
     * Regular before it ever becomes main/key. Refresh after renderer startup. */
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ipad_window_macos_presentation_refresh(); });
        return;
    }
    for (NSWindow *window in NSApp.windows) brand_video_window(window);
    if (NSApp.activationPolicy != NSApplicationActivationPolicyAccessory)
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

static void restore_minimized_video_windows(void)
{
    /* The controller explicitly activates this owned helper when the user asks
     * to show its video. Restore minimized video only at that activation edge;
     * frame updates and ordinary window notifications never raise it. */
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ restore_minimized_video_windows(); });
        return;
    }
    Class video_window_class = NSClassFromString(@"GstGLNSWindow");
    if (!video_window_class) return;
    for (NSWindow *window in NSApp.windows) {
        if ([window isKindOfClass:video_window_class] && window.isMiniaturized)
            [window deminiaturize:nil];
    }
}

void ipad_window_macos_presentation_install(void)
{
    @autoreleasepool {
        if (main_window_observer) return;
        /* Install before gst_macos_main, without creating NSApplication early or
         * changing the delegate/activation policy owned by that GStreamer wrapper. */
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        main_window_observer = [center addObserverForName:NSWindowDidBecomeMainNotification
            object:nil queue:nil usingBlock:^(NSNotification *note) { video_window_became_active(note); }];
        key_window_observer = [center addObserverForName:NSWindowDidBecomeKeyNotification
            object:nil queue:nil usingBlock:^(NSNotification *note) { video_window_became_active(note); }];
        application_active_observer = [center addObserverForName:NSApplicationDidBecomeActiveNotification
            object:nil queue:nil usingBlock:^(NSNotification *note) { restore_minimized_video_windows(); }];
    }
}
