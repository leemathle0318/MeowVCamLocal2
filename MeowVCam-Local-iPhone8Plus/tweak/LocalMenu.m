#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <notify.h>
#import <QuartzCore/QuartzCore.h>
#import <PhotosUI/PhotosUI.h>
#import "../core/MMHotkey.h"

static NSString *const preferences = @"/var/mobile/Library/Preferences/com.meowmeow.vcam.local.plist";
static MMHotkey keyState;
static void (*originalIncrease)(id, SEL);
static void (*originalDecrease)(id, SEL);
@interface MMLocalMenu : NSObject <UIDocumentPickerDelegate, PHPickerViewControllerDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, weak) UIWindow *previousWindow;
@property(nonatomic) BOOL importing;
@property(atomic) BOOL cancelImport;
@property(nonatomic, strong) NSProgress *importProgress;
@property(nonatomic, strong) NSItemProvider *importProvider;
+ (instancetype)shared;
- (void)show;
- (void)importURL:(NSURL *)url error:(NSError *)error;
- (void)finishImport:(NSString *)destination error:(NSString *)error;
@end
static void saveSource(NSString *source, BOOL enabled) {
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:preferences] mutableCopy] ?: [NSMutableDictionary new];
    d[@"enabled"] = @(enabled); d[@"mode"] = @"local";
    d[@"audioMode"] = @"mix";
    if (source) d[@"source"] = source;
    d[@"loop"] = @YES;
    if (!d[@"videoLongEdge"]) d[@"videoLongEdge"] = @720;
    [NSFileManager.defaultManager createDirectoryAtPath:preferences.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    if ([d writeToFile:preferences atomically:YES]) {
        /* SpringBoard normally runs as mobile, so preferences keep that owner. */
        notify_post("com.meowmeow.vcam.local.changed");
    } else NSLog(@"[MeowVCamLocal] Could not save local video preferences.");
}
@implementation MMLocalMenu
+ (instancetype)shared {
    static MMLocalMenu *menu; static dispatch_once_t once;
    dispatch_once(&once, ^{ menu = [MMLocalMenu new]; }); return menu;
}
- (void)close {
    self.window.userInteractionEnabled = NO;
    [self.window resignKeyWindow];
    self.window.hidden = YES; self.window = nil;
    [self.previousWindow makeKeyWindow]; self.previousWindow = nil;
}
- (void)prepareWindow {
    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes)
        if ([candidate isKindOfClass:UIWindowScene.class] && candidate.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)candidate; break;
        }
    for (UIWindow *w in scene.windows) if (w.isKeyWindow) { self.previousWindow = w; break; }
    self.window = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.frame = UIScreen.mainScreen.bounds;
    self.window.windowLevel = UIWindowLevelAlert + 1;
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = UIColor.clearColor;
    [self.window makeKeyAndVisible];
    __weak UIWindow *preparedWindow = self.window;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (preparedWindow && self.window == preparedWindow &&
            !self.window.rootViewController.presentedViewController) [self close];
    });
}
- (void)show {
    // The same physical-key sequence is an escape hatch for a stuck overlay.
    if (self.window) { [self close]; return; }
    [self prepareWindow];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"本地视频摄像头"
        message:self.importing ? @"视频正在后台导入，手机可以继续操作。" : @"画面替换摄像头；视频原声与现场麦克风混音，默认循环播放。"
        preferredStyle:UIAlertControllerStyleAlert];
    if (!self.importing) {
    [menu addAction:[UIAlertAction actionWithTitle:@"从相册选择视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        [self.window.rootViewController dismissViewControllerAnimated:NO completion:^{
            PHPickerConfiguration *configuration = [PHPickerConfiguration new];
            configuration.filter = [PHPickerFilter videosFilter];
            configuration.selectionLimit = 1;
            configuration.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
            PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
            picker.delegate = self;
            picker.modalPresentationStyle = UIModalPresentationFullScreen;
            [self.window.rootViewController presentViewController:picker animated:YES completion:nil];
        }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"选择视频（文件）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        [self.window.rootViewController dismissViewControllerAnimated:NO completion:^{
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
                initForOpeningContentTypes:@[UTTypeMovie] asCopy:NO];
            picker.allowsMultipleSelection = NO; picker.delegate = self;
            picker.modalPresentationStyle = UIModalPresentationFullScreen;
            [self.window.rootViewController presentViewController:picker animated:YES completion:nil];
        }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"输入手机现有文件路径" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        [self.window.rootViewController dismissViewControllerAnimated:NO completion:^{
            UIAlertController *path = [UIAlertController alertControllerWithTitle:@"本地视频路径"
                message:@"输入手机能读取的完整路径，例如 /var/mobile/Media/long.mp4。不会复制该文件。"
                preferredStyle:UIAlertControllerStyleAlert];
            [path addTextFieldWithConfigurationHandler:^(UITextField *field) {
                field.text = [NSDictionary dictionaryWithContentsOfFile:preferences][@"source"];
                field.autocorrectionType = UITextAutocorrectionTypeNo;
                field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            }];
            [path addAction:[UIAlertAction actionWithTitle:@"启用" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                (void)a; NSString *source = [path.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if ([source hasPrefix:@"/"] && [NSFileManager.defaultManager isReadableFileAtPath:source]) saveSource(source, YES);
                else NSLog(@"[MeowVCamLocal] Selected path is not an accessible absolute file path.");
                [self close];
            }]];
            [path addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { (void)a; [self close]; }]];
            [self.window.rootViewController presentViewController:path animated:YES completion:nil];
        }];
    }]];
    } else {
    [menu addAction:[UIAlertAction actionWithTitle:@"取消导入" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action; self.cancelImport = YES; [self.importProgress cancel]; [self close];
    }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"停止替换" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action; self.cancelImport = YES; [self.importProgress cancel]; saveSource(nil, NO); [self close];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { (void)action; [self close]; }]];
    [self.window.rootViewController presentViewController:menu animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [controller dismissViewControllerAnimated:NO completion:nil]; [self close];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) { [self close]; return; }
    self.importing = YES; self.cancelImport = NO;
    [controller dismissViewControllerAnimated:NO completion:nil];
    [self close];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self importURL:url error:nil];
    });
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    NSItemProvider *provider = results.firstObject.itemProvider;
    if (!provider) { [picker dismissViewControllerAnimated:NO completion:nil]; [self close]; return; }
    self.importing = YES; self.cancelImport = NO;
    [picker dismissViewControllerAnimated:NO completion:nil];
    [self close];
    self.importProvider = provider;
        if (![provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) {
            [self finishImport:nil error:@"所选项目没有可读取的视频文件。"]; return;
        }
        self.importProgress = [provider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier
            completionHandler:^(NSURL *url, NSError *error) {
                // Provider-owned temporary files are only valid in this handler.
                // Copy here, not in a subsequently dispatched block.
                if (NSThread.isMainThread) {
                    [self finishImport:nil error:@"系统在主线程返回视频，已取消导入以避免卡住桌面。请暂时使用文件入口。"]; return;
                }
                [self importURL:url error:error];
            }];
}
- (void)finishImport:(NSString *)destination error:(NSString *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL cancelled = self.cancelImport;
        self.importing = NO; self.importProgress = nil; self.importProvider = nil;
        if (cancelled) {
            if (destination) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
            });
            return;
        }
        if (destination) saveSource(destination, YES);
        if (self.window) return;
        [self prepareWindow];
        UIAlertController *result = [UIAlertController alertControllerWithTitle:destination ? @"视频已导入" : @"导入失败"
            message:destination ? @"已发送循环播放配置。视频原声与现场麦克风混音，实际声音接入需在设备上确认。" : error
            preferredStyle:UIAlertControllerStyleAlert];
        [result addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action; [self close];
        }]];
        [self.window.rootViewController presentViewController:result animated:YES completion:nil];
        // A result overlay must never remain indefinitely over SpringBoard.
        __weak UIWindow *resultWindow = self.window;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (resultWindow && self.window == resultWindow) [self close];
        });
    });
}
- (void)importURL:(NSURL *)url error:(NSError *)error {
    @autoreleasepool {
    if (!url || error || self.cancelImport) {
        [self finishImport:nil error:error.localizedDescription ?: @"视频导入已取消或文件不可用。"]; return;
    }
    /* Files providers expose temporary scoped URLs. Copy in fixed-size chunks to
     * a path the media daemon can read, without loading the video into NSData. */
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSString *directory = @"/var/mobile/Media/MeowVCamLocal";
        NSFileManager *files = NSFileManager.defaultManager;
        [files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
        NSString *temporary = [directory stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".tmp"]];
        NSString *suffix = url.pathExtension.length ? url.pathExtension : @"mp4";
        NSString *destination = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", NSUUID.UUID.UUIDString, suffix]];
        NSInputStream *input = [NSInputStream inputStreamWithURL:url];
        NSOutputStream *output = [NSOutputStream outputStreamToFileAtPath:temporary append:NO];
        [input open]; [output open];
        uint8_t *buffer = malloc(1024 * 1024); BOOL ok = buffer && input && output;
        while (ok && !self.cancelImport) {
            NSInteger n = [input read:buffer maxLength:1024 * 1024];
            if (n == 0) break;
            if (n < 0) { ok = NO; break; }
            NSInteger position = 0;
            while (position < n) {
                NSInteger written = [output write:buffer + position maxLength:n - position];
                if (written <= 0) { ok = NO; break; }
                position += written;
            }
        }
        free(buffer); [input close]; [output close];
        if (scoped) [url stopAccessingSecurityScopedResource];
        if (self.cancelImport) ok = NO;
        if (ok) ok = [files moveItemAtPath:temporary toPath:destination error:nil];
        if (ok) {
            [files setAttributes:@{NSFilePosixPermissions:@0644} ofItemAtPath:destination error:nil];
        } else { [files removeItemAtPath:temporary error:nil]; NSLog(@"[MeowVCamLocal] File import failed; existing source kept."); }
        [self finishImport:ok ? destination : nil error:@"请检查文件读取权限、相册视频是否已下载和手机剩余存储空间。"];
    }
}
@end
static void onButton(int button) {
    double timestamp = CACurrentMediaTime();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (mm_hotkey_press(&keyState, button, timestamp)) [[MMLocalMenu shared] show];
    });
}
static void increase(id object, SEL selector) { originalIncrease(object, selector); onButton(1); }
static void decrease(id object, SEL selector) { originalDecrease(object, selector); onButton(-1); }
__attribute__((constructor)) static void installVolumeMenu(void) {
    @autoreleasepool {
        Class volume = objc_getClass("SBVolumeControl");
        SEL up = sel_registerName("increaseVolume"), down = sel_registerName("decreaseVolume");
        Method u = volume ? class_getInstanceMethod(volume, up) : NULL;
        Method d = volume ? class_getInstanceMethod(volume, down) : NULL;
        char ur[16] = {0}, dr[16] = {0};
        if (u) method_getReturnType(u, ur, sizeof(ur));
        if (d) method_getReturnType(d, dr, sizeof(dr));
        if (u && d && method_getNumberOfArguments(u) == 2 && method_getNumberOfArguments(d) == 2 && ur[0] == 'v' && dr[0] == 'v') {
            MSHookMessageEx(volume, up, (IMP)increase, (IMP *)&originalIncrease);
            MSHookMessageEx(volume, down, (IMP)decrease, (IMP *)&originalDecrease);
            NSLog(@"[MeowVCamLocal] Volume up -> down menu hook installed.");
        } else NSLog(@"[MeowVCamLocal] Unsupported volume-control methods; use the preference file instead.");
    }
}
