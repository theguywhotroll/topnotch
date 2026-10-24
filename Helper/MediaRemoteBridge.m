// Loaded by /usr/bin/perl (see Resources/media-bridge.pl). Since macOS 15.4,
// MediaRemote only answers Apple-signed clients, so TopNotch reads the
// system now-playing state through this helper instead of in-process.
//
// Output: one JSON object per line on stdout whenever the state changes.
// Input: "c <command>" sends an MRMediaRemoteCommand; "s <seconds>" seeks.
// The helper exits when stdin closes, so it never outlives TopNotch.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendFn)(unsigned int, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);

static MRGetInfoFn getInfo;
static MRGetPIDFn getPID;
static MRGetPlayingFn getPlaying;
static MRSendFn sendCommand;
static MRSetElapsedFn setElapsed;
static dispatch_queue_t queue;
static NSString *lastLine;
static NSString *lastArtworkKey;
static NSString *lastArtwork;

static id value(NSDictionary *info, NSString *suffix) {
    return info[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:suffix]];
}

static void emit(void) {
    getInfo(queue, ^(CFDictionaryRef raw) {
        NSDictionary *info = [(__bridge NSDictionary *)raw copy];
        getPID(queue, ^(int pid) {
            getPlaying(queue, ^(Boolean playing) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"playing"] = @(playing);
                NSRunningApplication *app = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
                if (app.bundleIdentifier) out[@"bundle"] = app.bundleIdentifier;
                if (info) {
                    for (NSString *key in @[@"Title", @"Artist", @"Album"]) {
                        id v = value(info, key);
                        if ([v isKindOfClass:NSString.class]) out[key.lowercaseString] = v;
                    }
                    for (NSString *key in @[@"Duration", @"ElapsedTime", @"PlaybackRate"]) {
                        id v = value(info, key);
                        if ([v isKindOfClass:NSNumber.class]) out[key.lowercaseString] = v;
                    }
                    id timestamp = value(info, @"Timestamp");
                    if ([timestamp isKindOfClass:NSDate.class]) out[@"timestamp"] = @([timestamp timeIntervalSince1970]);
                    id identifier = value(info, @"ContentItemIdentifier") ?: value(info, @"UniqueIdentifier");
                    if (identifier) out[@"id"] = [identifier description];
                    id artwork = value(info, @"ArtworkData");
                    if ([artwork isKindOfClass:NSData.class]) {
                        NSString *key = [NSString stringWithFormat:@"%@|%lu", out[@"id"] ?: out[@"title"], (unsigned long)[artwork length]];
                        if (![key isEqualToString:lastArtworkKey]) {
                            lastArtworkKey = key;
                            lastArtwork = [artwork base64EncodedStringWithOptions:0];
                        }
                        out[@"artwork"] = lastArtwork;
                    }
                }
                NSData *json = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
                NSString *line = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
                if (line && ![line isEqualToString:lastLine]) {
                    lastLine = line;
                    printf("%s\n", line.UTF8String);
                    fflush(stdout);
                }
            });
        });
    });
}

static void readCommands(void) {
    char buffer[256];
    while (fgets(buffer, sizeof buffer, stdin)) {
        if (buffer[0] == 'c') {
            sendCommand((unsigned int)strtoul(buffer + 2, NULL, 10), NULL);
        } else if (buffer[0] == 's') {
            setElapsed(strtod(buffer + 2, NULL));
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), queue, ^{ emit(); });
    }
    exit(0);
}

void topnotch_media_stream(void *interpreter, void *cv) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!handle) exit(2);
    getInfo = (MRGetInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
    getPID = (MRGetPIDFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
    getPlaying = (MRGetPlayingFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    sendCommand = (MRSendFn)dlsym(handle, "MRMediaRemoteSendCommand");
    setElapsed = (MRSetElapsedFn)dlsym(handle, "MRMediaRemoteSetElapsedTime");
    MRRegisterFn registerForNotifications = (MRRegisterFn)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getPID || !getPlaying || !sendCommand || !setElapsed || !registerForNotifications) exit(3);

    queue = dispatch_queue_create("topnotch.media", DISPATCH_QUEUE_SERIAL);
    registerForNotifications(queue);
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(queue, ^{ emit(); });
        }];
    }
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{ emit(); });
    dispatch_resume(timer);
    [NSThread detachNewThreadWithBlock:^{ readCommands(); }];
    CFRunLoopRun();
}
