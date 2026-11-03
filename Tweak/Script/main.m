//
//  main.m
//  kayoko_script
//
//  Runs a single user script against a single input string and prints the result as JSON.
//
//  Protocol (v2)
//    stdin:  {"code": "<javascript source>", "input": "<text>", "clipboard": {"text": "<text>"}, "limits": {...}}
//    stdout: {"items": [{"type": "txt", "title": "...", "content": "..."}]} or {"error": "...", "code": "..."}
//
//  A script has to define a global function `main(text)`. It may return a single string, an array of strings (both
//  are the v1 shape and stay valid), a dictionary, or an array of dictionaries. Strings become `txt` items; a
//  dictionary opts into an action (`txt`, `pb`, `url`, `urlInApp`, `app`) and may carry a `title` for the picker.
//  Scripts can read the clipboard through `$pb.readString()`; it is pre-read by the host before the script starts.
//

#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

#import <errno.h>
#import <pthread.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/resource.h>
#import <unistd.h>

static NSUInteger const kKayokoScriptMaximumInputBytes = 4 * 1024 * 1024;
static NSUInteger const kKayokoScriptMaximumResults = 100;
static NSUInteger const kKayokoScriptMaximumResultLength = 50000;
static NSUInteger const kKayokoScriptMaximumTotalLength = 200000;
static NSTimeInterval const kKayokoScriptDefaultTimeout = 5.0;
static NSUInteger const kKayokoScriptMaximumActionLength = 2048;
static NSUInteger const kKayokoScriptMaximumTitleLength = 200;

// KEEP IN SYNC with KayokoScriptItem.m: the host maps these back to its own enum, and a mismatch turns into a
// "the script runner returned an unexpected response" failure instead of a result.
static NSString *const kKayokoScriptItemTypeText = @"txt";
static NSString *const kKayokoScriptItemTypePasteboard = @"pb";
static NSString *const kKayokoScriptItemTypeURL = @"url";
static NSString *const kKayokoScriptItemTypeURLInApp = @"urlInApp";
static NSString *const kKayokoScriptItemTypeApplication = @"app";

#pragma mark - Output

static pthread_mutex_t kKayokoEmitLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL kKayokoDidEmitPayload = NO;

static BOOL kayokoHasEmittedPayload(void) {
    pthread_mutex_lock(&kKayokoEmitLock);
    BOOL emitted = kKayokoDidEmitPayload;
    pthread_mutex_unlock(&kKayokoEmitLock);
    return emitted;
}

static void kayokoEmitPayload(NSDictionary<NSString *, id> *payload) {
    pthread_mutex_lock(&kKayokoEmitLock);
    BOOL alreadyEmitted = kKayokoDidEmitPayload;
    kKayokoDidEmitPayload = YES;
    pthread_mutex_unlock(&kKayokoEmitLock);

    if (alreadyEmitted) {
        return;
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    if ([data length] > 0) {
        fwrite([data bytes], 1, [data length], stdout);
        fflush(stdout);
    }
}

static void kayokoEmitItems(NSArray<NSDictionary<NSString *, id> *> *items) {
    kayokoEmitPayload(@{@"items" : items ?: @[]});
}

/// Extra keys ride along with the error so the panel can explain the failure instead of repeating it: the line
/// a script broke on, the type it returned, the limit it crossed.
static void kayokoEmitError(NSString *code, NSString *message, NSDictionary<NSString *, id> *extra) {
    NSMutableDictionary<NSString *, id> *payload =
        [@{@"error" : message ?: @"Script failed", @"code" : code ?: @"failure"} mutableCopy];
    for (NSString *key in extra) {
        id value = [extra objectForKey:key];
        if (value) {
            [payload setObject:value forKey:key];
        }
    }
    kayokoEmitPayload(payload);
}

#pragma mark - Watchdog

// JavaScriptCore has no interrupt API, so the only reliable way out of a runaway script is to leave the
// process. The parent enforces its own hard timeout with SIGKILL as well.
static void *kayokoWatchdogMain(void *context) {
    @autoreleasepool {
        NSTimeInterval timeout = *(NSTimeInterval *)context;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];

        while ([deadline timeIntervalSinceNow] > 0) {
            usleep(50 * 1000);
            if (kayokoHasEmittedPayload()) {
                return NULL;
            }
        }

        if (kayokoHasEmittedPayload()) {
            return NULL;
        }

        kayokoEmitError(@"timeout", @"Script timed out",
                        @{@"seconds" : @(timeout), @"stage" : @"run"});
        _exit(1);
    }
}
#pragma mark - Input

static NSData *kayokoReadAllFromDescriptor(int descriptor, NSUInteger limit, BOOL *exceeded) {
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[32768];

    while (YES) {
        ssize_t count = read(descriptor, buffer, sizeof(buffer));
        if (count > 0) {
            [data appendBytes:buffer length:(NSUInteger)count];
            if ([data length] > limit) {
                if (exceeded) {
                    *exceeded = YES;
                }
                return nil;
            }
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        break;
    }

    return data;
}

#pragma mark - JavaScript

static NSString *kayokoDescribeException(JSContext *context) {
    JSValue *exception = [context exception];
    if (!exception || [exception isUndefined] || [exception isNull]) {
        return @"Script error";
    }

    NSString *message = nil;
    JSValue *messageValue = [exception valueForProperty:@"message"];
    if ([messageValue isString]) {
        message = [messageValue toString];
    }
    if ([message length] == 0) {
        message = [exception toString];
    }

    return [message length] > 0 ? message : @"Script error";
}

static NSInteger kayokoExceptionInteger(JSValue *exception, NSString *key) {
    JSValue *value = [exception valueForProperty:key];
    if (![value isNumber]) {
        return 0;
    }

    NSInteger number = (NSInteger)[value toInt32];
    return number > 0 ? number : 0;
}

/// The user wrote the line, so showing it back is worth more than any wording this side can invent.
static NSString *kayokoSourceLineAt(NSString *code, NSInteger line) {
    if (line <= 0) {
        return nil;
    }

    NSArray<NSString *> *lines = [code componentsSeparatedByString:@"\n"];
    if ((NSUInteger)line > [lines count]) {
        return nil;
    }

    NSString *text = [lines[(NSUInteger)line - 1]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([text length] > 200) {
        text = [[text substringToIndex:200] stringByAppendingString:@"…"];
    }

    return [text length] > 0 ? text : nil;
}

/// Where a script broke: which stage, which line, and the line itself.
static NSDictionary<NSString *, id> *kayokoExceptionDetails(JSContext *context,
                                                           NSString *stage,
                                                           NSString *code) {
    JSValue *exception = [context exception];
    if (!exception || [exception isUndefined] || [exception isNull]) {
        return @{@"stage" : stage};
    }

    NSInteger line = kayokoExceptionInteger(exception, @"line");
    NSInteger column = kayokoExceptionInteger(exception, @"column");

    NSMutableDictionary<NSString *, id> *details = [@{@"stage" : stage} mutableCopy];
    if (line > 0) {
        [details setObject:@(line) forKey:@"line"];
    }
    if (column > 0) {
        [details setObject:@(column) forKey:@"column"];
    }

    NSString *sourceLine = kayokoSourceLineAt(code, line);
    if ([sourceLine length] > 0) {
        [details setObject:sourceLine forKey:@"source"];
    }

    return details;
}

static NSString *kayokoDescribeType(JSValue *value) {
    if (!value || [value isUndefined]) {
        return @"undefined";
    }
    if ([value isNull]) {
        return @"null";
    }
    if ([value isArray]) {
        return @"array";
    }
    if ([value isObject]) {
        return @"object";
    }
    if ([value isNumber]) {
        return @"number";
    }
    if ([value isBoolean]) {
        return @"boolean";
    }
    return @"unknown";
}

static NSMutableDictionary<NSString *, id> *kayokoItemExtras(NSUInteger itemIndex) {
    NSMutableDictionary<NSString *, id> *extras = [@{@"stage" : @"run"} mutableCopy];
    if (itemIndex > 0) {
        [extras setObject:@(itemIndex) forKey:@"index"];
    }
    return extras;
}

static BOOL kayokoIsSupportedItemType(NSString *type) {
    return [type isEqualToString:kKayokoScriptItemTypeText] ||
           [type isEqualToString:kKayokoScriptItemTypePasteboard] ||
           [type isEqualToString:kKayokoScriptItemTypeURL] ||
           [type isEqualToString:kKayokoScriptItemTypeURLInApp] ||
           [type isEqualToString:kKayokoScriptItemTypeApplication];
}

/// Only the two web schemes are allowed: everything else (`javascript:`, `file:`, `data:`, or an arbitrary app
/// scheme) either has no business being triggered by a clipboard script or is a way to smuggle an action past the
/// person who is about to tap it.
static NSString *kayokoURLScheme(NSString *text) {
    NSRange separator = [text rangeOfString:@"://"];
    if (separator.location == NSNotFound || separator.location == 0) {
        return nil;
    }

    return [[text substringToIndex:separator.location] lowercaseString];
}

static BOOL kayokoIsBundleIdentifier(NSString *text) {
    if ([text length] == 0 || [text length] > 255) {
        return NO;
    }

    NSCharacterSet *allowed = [NSCharacterSet
        characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [text rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound;
}

/// One entry of the result list. A bare string is the v1 shape and stays valid; a dictionary opts into an action.
static NSDictionary<NSString *, id> *kayokoItemFromValue(JSValue *value,
                                                        NSUInteger itemIndex,
                                                        NSUInteger maxResultLength,
                                                        NSString **errorCode,
                                                        NSString **errorMessage,
                                                        NSDictionary<NSString *, id> **errorExtra,
                                                        BOOL *skipped) {
    *skipped = NO;

    NSString *type = kKayokoScriptItemTypeText;
    JSValue *contentValue = value;
    NSString *title = nil;

    BOOL isDictionaryItem = ![value isString] && ![value isArray] && [value isObject];
    if (isDictionaryItem) {
        JSValue *typeValue = [value valueForProperty:@"type"];
        if (![typeValue isString] || [[typeValue toString] length] == 0) {
            *errorCode = @"bad-item-type";
            *errorMessage = @"Item is missing a type";
            *errorExtra = kayokoItemExtras(itemIndex);
            return nil;
        }

        type = [typeValue toString];
        if (!kayokoIsSupportedItemType(type)) {
            *errorCode = @"bad-item-type";
            *errorMessage = @"Unknown item type";
            NSMutableDictionary *extras = kayokoItemExtras(itemIndex);
            [extras setObject:type forKey:@"type"];
            *errorExtra = extras;
            return nil;
        }

        JSValue *titleValue = [value valueForProperty:@"title"];
        if ([titleValue isString] && [[titleValue toString] length] > 0) {
            title = [titleValue toString];
            if ([title length] > kKayokoScriptMaximumTitleLength) {
                title = [title substringToIndex:kKayokoScriptMaximumTitleLength];
            }
        }

        contentValue = [value valueForProperty:@"content"];
    }

    if (![contentValue isString]) {
        *errorCode = @"bad-item-content";
        *errorMessage = @"Item has no text content";
        NSMutableDictionary *extras = kayokoItemExtras(itemIndex);
        [extras setObject:type forKey:@"type"];
        [extras setObject:kayokoDescribeType(contentValue) forKey:@"value"];
        *errorExtra = extras;
        return nil;
    }

    NSString *content = [contentValue toString];

    // v1 dropped empty strings silently and scripts in the wild rely on it (`text.split('\n')` leaves a trailing
    // empty element), so only an explicit dictionary is allowed to fail on empty content.
    if ([content length] == 0) {
        if (!isDictionaryItem && [type isEqualToString:kKayokoScriptItemTypeText]) {
            *skipped = YES;
            return nil;
        }

        *errorCode = @"bad-item-content";
        *errorMessage = @"Item has empty content";
        NSMutableDictionary *extras = kayokoItemExtras(itemIndex);
        [extras setObject:type forKey:@"type"];
        *errorExtra = extras;
        return nil;
    }

    if ([type isEqualToString:kKayokoScriptItemTypeURL] || [type isEqualToString:kKayokoScriptItemTypeURLInApp]) {
        if ([content length] > kKayokoScriptMaximumActionLength) {
            *errorCode = @"bad-item-content";
            *errorMessage = @"Link is too long";
            NSMutableDictionary *extras = kayokoItemExtras(itemIndex);
            [extras setObject:@([content length]) forKey:@"length"];
            [extras setObject:@(kKayokoScriptMaximumActionLength) forKey:@"limit"];
            *errorExtra = extras;
            return nil;
        }

        NSString *scheme = kayokoURLScheme(content);
        if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
            *errorCode = @"action-blocked";
            *errorMessage = @"Only http and https links can be opened";
            NSMutableDictionary *extras = kayokoItemExtras(itemIndex);
            [extras setObject:(scheme ?: @"none") forKey:@"scheme"];
            *errorExtra = extras;
            return nil;
        }
    } else if ([type isEqualToString:kKayokoScriptItemTypeApplication]) {
        if ([content length] > kKayokoScriptMaximumActionLength || !kayokoIsBundleIdentifier(content)) {
            *errorCode = @"bad-item-content";
            *errorMessage = @"Not a bundle identifier";
            NSMutableDictionary *extras = kayokoItemExtras(itemIndex);
            [extras setObject:type forKey:@"type"];
            *errorExtra = extras;
            return nil;
        }
    } else if ([content length] > maxResultLength) {
        *errorCode = @"result-too-large";
        *errorMessage = @"Result is too large";
        NSMutableDictionary *extras = kayokoItemExtras(itemIndex);
        [extras setObject:@([content length]) forKey:@"length"];
        [extras setObject:@(maxResultLength) forKey:@"limit"];
        *errorExtra = extras;
        return nil;
    }

    NSMutableDictionary<NSString *, id> *item = [@{@"type" : type, @"content" : content} mutableCopy];
    if ([title length] > 0) {
        [item setObject:title forKey:@"title"];
    }
    return item;
}

static NSArray<NSDictionary<NSString *, id> *> *kayokoNormalizeItems(JSValue *value,
                                                                   NSUInteger maxResults,
                                                                   NSUInteger maxResultLength,
                                                                   NSUInteger maxTotalLength,
                                                                   NSString **errorCode,
                                                                   NSString **errorMessage,
                                                                   NSDictionary<NSString *, id> **errorExtra) {
    if (!value || [value isUndefined] || [value isNull]) {
        return @[];
    }

    BOOL isList = [value isArray];
    NSUInteger count = 1;
    if (isList) {
        JSValue *lengthValue = [value valueForProperty:@"length"];
        count = [lengthValue isUndefined] ? 0 : [lengthValue toUInt32];
    }
    if (count == 0) {
        return @[];
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *items = [NSMutableArray arrayWithCapacity:MIN(count, maxResults)];
    NSUInteger totalLength = 0;

    for (NSUInteger index = 0; index < count; index++) {
        if ([items count] >= maxResults) {
            *errorCode = @"too-many-results";
            *errorMessage = @"Too many results";
            *errorExtra = @{@"stage" : @"run", @"count" : @([items count]), @"limit" : @(maxResults)};
            return nil;
        }

        JSValue *element = isList ? [value valueAtIndex:index] : value;
        BOOL skipped = NO;
        NSDictionary<NSString *, id> *item =
            kayokoItemFromValue(element, isList ? index + 1 : 0, maxResultLength, errorCode, errorMessage, errorExtra,
                                &skipped);
        if (!item) {
            if (skipped) {
                continue;
            }
            return nil;
        }

        totalLength += [(NSString *)[item objectForKey:@"content"] length];
        if (totalLength > maxTotalLength) {
            *errorCode = @"result-too-large";
            *errorMessage = @"Too much text in total";
            *errorExtra = @{@"stage" : @"run", @"length" : @(totalLength), @"limit" : @(maxTotalLength)};
            return nil;
        }

        [items addObject:item];
    }

    return items;
}

/// Reads the optional `limits` block of the request and clamps every value into a safe range, so a malformed or
/// hostile request can never raise a limit past what the watchdog and pipes can actually honour.
static void kayokoParseLimits(NSDictionary *request,
                              NSUInteger *maxResults,
                              NSUInteger *maxResultLength,
                              NSUInteger *maxTotalLength) {
    *maxResults = kKayokoScriptMaximumResults;
    *maxResultLength = kKayokoScriptMaximumResultLength;
    *maxTotalLength = kKayokoScriptMaximumTotalLength;

    id rawLimits = [request objectForKey:@"limits"];
    if (![rawLimits isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSDictionary *limits = (NSDictionary *)rawLimits;

    id rawResults = [limits objectForKey:@"maxResults"];
    if ([rawResults isKindOfClass:[NSNumber class]]) {
        NSUInteger value = [rawResults unsignedIntegerValue];
        *maxResults = MIN(MAX(value, 1), 2000);
    }

    id rawLength = [limits objectForKey:@"maxResultLength"];
    if ([rawLength isKindOfClass:[NSNumber class]]) {
        NSUInteger value = [rawLength unsignedIntegerValue];
        *maxResultLength = MIN(MAX(value, 1000), 500000);
    }

    *maxTotalLength = MIN(*maxResultLength * 4, 2000000);
}

static NSArray<NSDictionary<NSString *, id> *> *kayokoRunScript(NSString *code,
                                                               NSString *input,
                                                               NSString *clipboardText,
                                                               NSUInteger maxResults,
                                                               NSUInteger maxResultLength,
                                                               NSUInteger maxTotalLength,
                                                               NSString **errorCode,
                                                               NSString **errorMessage,
                                                               NSDictionary<NSString *, id> **errorExtra) {
    JSContext *context = [[JSContext alloc] init];

    [context setObject:^(JSValue *message) {
      NSString *text = [message isString] ? [message toString] : nil;
      if ([text length] > 0) {
          fprintf(stderr, "%s\n", [text UTF8String]);
      }
    }
                forKeyedSubscript:@"__kayokoLog"];

    // The clipboard arrives pre-read by the host instead of being queried back over the pipe: the request is a
    // single write, so anything the script wants has to be in it before `main` starts.
    NSString *injectedClipboard = clipboardText ?: @"";
    [context setObject:^NSString *(void) {
      return injectedClipboard;
    }
                forKeyedSubscript:@"__kayokoClipboardText"];

    // Scripts get a console shim and a read-only clipboard; there is no filesystem, network or host bridge.
    [context evaluateScript:@"var console = {"
                              @"  log: function () { __kayokoLog(Array.prototype.slice.call(arguments).map(String).join(' ')); },"
                              @"  info: function () { console.log.apply(console, arguments); },"
                              @"  warn: function () { console.log.apply(console, arguments); },"
                              @"  error: function () { console.log.apply(console, arguments); },"
                              @"  debug: function () { console.log.apply(console, arguments); }"
                              @"};"
                              @"var $pb = { readString: function () { return __kayokoClipboardText(); } };"];

    [context evaluateScript:code];
    if ([context exception]) {
        // The source itself was rejected, so there is no "while running" to speak of.
        *errorCode = @"exception";
        *errorMessage = kayokoDescribeException(context);
        *errorExtra = kayokoExceptionDetails(context, @"compile", code);
        return nil;
    }

    JSValue *isFunction = [context evaluateScript:@"typeof main === 'function'"];
    if (![isFunction toBool]) {
        *errorCode = @"no-main";
        *errorMessage = @"Missing main(text)";
        *errorExtra = @{@"stage" : @"compile"};
        return nil;
    }

    JSValue *main = context[@"main"];
    JSValue *value = [main callWithArguments:@[ input ?: @"" ]];
    if ([context exception]) {
        *errorCode = @"exception";
        *errorMessage = kayokoDescribeException(context);
        *errorExtra = kayokoExceptionDetails(context, @"run", code);
        return nil;
    }

    return kayokoNormalizeItems(value, maxResults, maxResultLength, maxTotalLength, errorCode, errorMessage,
                                errorExtra);
}

#pragma mark - Entry Point

static NSTimeInterval kayokoTimeoutFromArguments(int argc, char *argv[]) {
    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "-t") == 0 && index + 1 < argc) {
            double value = strtod(argv[index + 1], NULL);
            if (value >= 0.5 && value <= 30.0) {
                return value;
            }
        }
    }

    return kKayokoScriptDefaultTimeout;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // A runaway script must not be able to spin forever, so give the kernel a backstop as well.
        NSTimeInterval timeout = kayokoTimeoutFromArguments(argc, argv);
        struct rlimit cpuLimit = {(rlim_t)(timeout + 1.0), (rlim_t)(timeout + 2.0)};
        setrlimit(RLIMIT_CPU, &cpuLimit);

        BOOL inputExceededLimit = NO;
        NSData *input = kayokoReadAllFromDescriptor(STDIN_FILENO, kKayokoScriptMaximumInputBytes,
                                                    &inputExceededLimit);
        if (inputExceededLimit) {
            kayokoEmitError(@"input-too-large", @"Input is too large",
                            @{@"limit" : @(kKayokoScriptMaximumInputBytes)});
            return 1;
        }
        if ([input length] == 0) {
            kayokoEmitError(@"invalid-request", @"Request is empty", nil);
            return 1;
        }

        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:input options:0 error:NULL];
        if (![request isKindOfClass:[NSDictionary class]]) {
            kayokoEmitError(@"invalid-request", @"Request is not a dictionary", nil);
            return 1;
        }

        id code = [request objectForKey:@"code"];
        id text = [request objectForKey:@"input"];
        if (![code isKindOfClass:[NSString class]] || [code length] == 0) {
            kayokoEmitError(@"invalid-request", @"Missing code", nil);
            return 1;
        }
        if (![text isKindOfClass:[NSString class]]) {
            text = @"";
        }

        NSUInteger maxResults = 0;
        NSUInteger maxResultLength = 0;
        NSUInteger maxTotalLength = 0;
        kayokoParseLimits(request, &maxResults, &maxResultLength, &maxTotalLength);

        id clipboard = [request objectForKey:@"clipboard"];
        NSString *clipboardText = @"";
        if ([clipboard isKindOfClass:[NSDictionary class]]) {
            id rawClipboardText = [(NSDictionary *)clipboard objectForKey:@"text"];
            if ([rawClipboardText isKindOfClass:[NSString class]]) {
                clipboardText = rawClipboardText;
            }
        }

        pthread_t watchdog = (pthread_t)0;
        if (pthread_create(&watchdog, NULL, kayokoWatchdogMain, &timeout) == 0) {
            pthread_detach(watchdog);
        }

        NSString *errorCode = nil;
        NSString *errorMessage = nil;
        NSDictionary<NSString *, id> *errorExtra = nil;
        NSArray<NSDictionary<NSString *, id> *> *items =
            kayokoRunScript(code, text, clipboardText, maxResults, maxResultLength, maxTotalLength, &errorCode,
                            &errorMessage, &errorExtra);
        if (!items) {
            kayokoEmitError(errorCode, errorMessage, errorExtra);
            return 1;
        }

        kayokoEmitItems(items);
        return 0;
    }
}
