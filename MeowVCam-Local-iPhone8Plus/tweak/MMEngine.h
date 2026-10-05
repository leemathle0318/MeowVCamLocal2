#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "../core/MMDecoder.h"
#import "../core/MMTimeline.h"
@interface MMEngine : NSObject
+ (instancetype)shared;
+ (NSDictionary *)configurationForCurrentApplication;
- (void)reloadConfiguration;
- (BOOL)startWithConfiguration:(NSDictionary *)configuration;
- (CMSampleBufferRef)copyVideoSample:(CMSampleBufferRef)original CF_RETURNS_RETAINED;
- (CMSampleBufferRef)copyAudioSample:(CMSampleBufferRef)original CF_RETURNS_RETAINED;
// buffers must already contain a copy of microphone PCM; video is added in place.
- (BOOL)fillAudioBuffers:(AudioBufferList *)buffers
                 format:(AudioStreamBasicDescription)format
                 frames:(UInt32)frames atTime:(double)seconds;
@property(nonatomic, readonly) NSString *audioMode;
@property(atomic, readonly) BOOL active;
@end
