#import "globals.h"
#import <math.h>

BOOL isBorderlessModeEnabled = NO;
BOOL isPopupVisible = NO;
BOOL isMouseLocked = NO;
BOOL fnMouseInputActive = YES;
_Atomic(bool) fnUnlockFrameRate = true;
_Atomic(bool) fnStayActive = true;
_Atomic(double) fnUserFrameLimit = 0;
UIWindow *popupWindow = nil;
NSDictionary *fnMenuShortcut;
NSDictionary *fnCursorShortcut;
NSDictionary *fnGraphicsShortcut;
void (^fnShortcutCapture)(NSDictionary *shortcut);
static NSURL *dataFolderURL;
static BOOL dataFolderAccess;

BOOL fnValidShortcut(id value, BOOL allowEmpty) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    if (![value count]) return allowEmpty;
    id code = value[@"code"], mods = value[@"modifiers"], label = value[@"label"];
    NSSet *nonKeyDownCodes = [NSSet setWithArray:@[@53, @54, @55, @56, @57, @58, @59, @60, @61, @62, @63]];
    if ([nonKeyDownCodes containsObject:code ?: NSNull.null]) return NO;
    return [code isKindOfClass:NSNumber.class] && [code integerValue] >= 0 && [code integerValue] < 128 &&
           [mods isKindOfClass:NSNumber.class] && ([mods unsignedIntegerValue] & ~0x1e0000UL) == 0 &&
           [label isKindOfClass:NSString.class] && [label length] > 0 && [label length] <= 64;
}

NSString *fnShortcutTitle(NSDictionary *shortcut) {
    if (!shortcut.count) return @"Not assigned";
    NSUInteger flags = [shortcut[@"modifiers"] unsignedIntegerValue];
    return [NSString stringWithFormat:@"%@%@%@%@%@", (flags & (1UL << 18)) ? @"⌃" : @"",
            (flags & (1UL << 19)) ? @"⌥" : @"", (flags & (1UL << 17)) ? @"⇧" : @"",
            (flags & (1UL << 20)) ? @"⌘" : @"", shortcut[@"label"]];
}

void fnLoadSettings(void) {
    NSUserDefaults *prefs = tweakDefaults();
    isBorderlessModeEnabled = [prefs boolForKey:kBorderlessWindowKey];
    fnUnlockFrameRate = [prefs objectForKey:kUnlockFrameRateKey] ? [prefs boolForKey:kUnlockFrameRateKey] : YES;
    fnStayActive = [prefs objectForKey:kStayActiveKey] ? [prefs boolForKey:kStayActiveKey] : YES;
    id menu = [prefs dictionaryForKey:kMenuShortcutKey], cursor = [prefs dictionaryForKey:kCursorShortcutKey];
    fnMenuShortcut = fnValidShortcut(menu, YES) ? menu : @{@"code": @35, @"modifiers": @0, @"label": @"P"};
    id graphics = [prefs dictionaryForKey:kGraphicsShortcutKey];
    fnGraphicsShortcut = fnValidShortcut(graphics, YES) ? graphics : @{};
    fnCursorShortcut = fnValidShortcut(cursor, YES) ? cursor : @{};
}

void fnSettingsChanged(void) {
    BOOL wasBorderless = isBorderlessModeEnabled;
    fnLoadSettings();
    if (!fnCursorShortcut.count) {
        fnFollowGameCursor();
    }
    if (wasBorderless != isBorderlessModeEnabled) updateBorderlessMode();
    [[NSNotificationCenter defaultCenter] postNotificationName:FnSettingsChangedNotification object:nil];
}

static NSData *bookmarkForFolder(NSURL *url, NSError **error) {
    return [url bookmarkDataWithOptions:(NSURLBookmarkCreationOptions)(1UL << 11)
        includingResourceValuesForKeys:nil relativeToURL:nil error:error];
}

BOOL fnSelectDataFolder(NSURL *url, NSError **error) {
    BOOL directory = NO;
    if (!url.isFileURL || ![[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:&directory] || !directory) {
        if (error) *error = [NSError errorWithDomain:@"FnMacTweakKBM" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Select the Fortnite data folder."}];
        return NO;
    }
    BOOL access = [url startAccessingSecurityScopedResource];
    NSData *bookmark = bookmarkForFolder(url, error);
    if (!bookmark) { if (access) [url stopAccessingSecurityScopedResource]; return NO; }
    if (dataFolderAccess) [dataFolderURL stopAccessingSecurityScopedResource];
    dataFolderURL = url;
    dataFolderAccess = access;
    [[NSUserDefaults standardUserDefaults] setObject:bookmark forKey:kDataFolderKey];
    return YES;
}

NSURL *fnDataFolder(void) {
    if (dataFolderURL) return dataFolderURL;
    NSData *bookmark = [[NSUserDefaults standardUserDefaults] dataForKey:kDataFolderKey];
    if (!bookmark) return nil;
    BOOL stale = NO;
    NSError *error = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
        options:(NSURLBookmarkResolutionWithoutUI | (NSURLBookmarkResolutionOptions)(1UL << 10))
        relativeToURL:nil bookmarkDataIsStale:&stale error:&error];
    if (!url) { NSLog(@"[FnMacTweak-kbm] Folder bookmark: %@", error.localizedDescription); return nil; }
    dataFolderAccess = [url startAccessingSecurityScopedResource];
    dataFolderURL = url;
    if (stale) {
        NSData *fresh = bookmarkForFolder(url, &error);
        if (fresh) [[NSUserDefaults standardUserDefaults] setObject:fresh forKey:kDataFolderKey];
    }
    return dataFolderURL;
}

// Follow Fortnite's PC frame-rate choice exposed by the external v3 patcher.
void fnReadGameFrameLimit(const char *path) {
    if (!path) return;
    NSStringEncoding encoding;
    NSString *text = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:path] usedEncoding:&encoding error:nil];
    if (!text) return;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (![line hasPrefix:@"FrameRateLimit="]) continue;
        double limit = [[line substringFromIndex:15] doubleValue];
        fnUserFrameLimit = isfinite(limit) && limit > 0 ? limit : 0;
    }
}
