#import "MMEngine.h"
#import <objc/runtime.h>
#import <substrate.h>
#import <notify.h>
#import <string.h>

static void (*originalVideo)(id, SEL, CMSampleBufferRef, BOOL, BOOL);
static void (*originalAudio)(id, SEL, CMSampleBufferRef, id);
static dispatch_queue_t controlQueue;
static BOOL sampleArgument(Method method, unsigned index) {
    char type[128] = {0}; method_getArgumentType(method, index, type, sizeof(type));
    return type[0] == '^' && strstr(type, "opaqueCMSampleBuffer") != NULL;
}
static BOOL returnVoid(Method method) {
    char type[16] = {0}; method_getReturnType(method, type, sizeof(type)); return type[0] == 'v';
}
static BOOL boolArgument(Method method, unsigned index) {
    char type[32] = {0}; method_getArgumentType(method, index, type, sizeof(type));
    return type[0] == 'B' || type[0] == 'c';
}
static void videoReplacement(id object, SEL selector, CMSampleBufferRef sample, BOOL controls, BOOL stills) {
    MMEngine *engine = [MMEngine shared];
    CMSampleBufferRef replacement = engine.active && sample ? [engine copyVideoSample:sample] : NULL;
    @try { originalVideo(object, selector, replacement ?: sample, controls, stills); }
    @finally { if (replacement) CFRelease(replacement); }
}
static void audioReplacement(id object, SEL selector, CMSampleBufferRef sample, id input) {
    MMEngine *engine = [MMEngine shared];
    BOOL alreadyMixed = sample && CMGetAttachment(sample,
        CFSTR("com.meowmeow.vcam.local.audioMixed"), NULL) != NULL;
    CMSampleBufferRef replacement = engine.active && sample && !alreadyMixed ? [engine copyAudioSample:sample] : NULL;
    @try { originalAudio(object, selector, replacement ?: sample, input); }
    @finally { if (replacement) CFRelease(replacement); }
}
__attribute__((constructor)) static void installLocalCapture(void) {
    @autoreleasepool {
        Class video = objc_getClass("BWFigVideoCaptureStream");
        SEL videoSelector = sel_registerName("sourceNodeWillEmitVideoSampleBuffer:drivesCameraControls:deliversStills:");
        Method vm = video ? class_getInstanceMethod(video, videoSelector) : NULL;
        if (vm && method_getNumberOfArguments(vm) == 5 && returnVoid(vm) &&
            sampleArgument(vm, 2) && boolArgument(vm, 3) && boolArgument(vm, 4)) {
            MSHookMessageEx(video, videoSelector, (IMP)videoReplacement, (IMP *)&originalVideo);
            NSLog(@"[MeowVCamLocal] System video hook installed.");
        } else NSLog(@"[MeowVCamLocal] Unsupported system video method signature; skipped.");
        Class audio = objc_getClass("BWAudioConverterNode");
        SEL audioSelector = sel_registerName("renderSampleBuffer:forInput:");
        Method am = audio ? class_getInstanceMethod(audio, audioSelector) : NULL;
        char inputType[64] = {0}; if (am) method_getArgumentType(am, 3, inputType, sizeof(inputType));
        if (am && method_getNumberOfArguments(am) == 4 && returnVoid(am) &&
            sampleArgument(am, 2) && inputType[0] == '@') {
            MSHookMessageEx(audio, audioSelector, (IMP)audioReplacement, (IMP *)&originalAudio);
            NSLog(@"[MeowVCamLocal] System audio hook installed.");
        } else NSLog(@"[MeowVCamLocal] Unsupported system audio method signature; skipped.");
        controlQueue = dispatch_queue_create("com.meowmeow.local.control", DISPATCH_QUEUE_SERIAL);
        [MMEngine shared];
        int token;
        notify_register_dispatch("com.meowmeow.vcam.local.changed", &token, controlQueue, ^(int t) {
            (void)t; @autoreleasepool { [[MMEngine shared] reloadConfiguration]; }
        });
        dispatch_async(controlQueue, ^{ [[MMEngine shared] reloadConfiguration]; });
    }
}
