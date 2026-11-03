//
//  main.m
//  kayoko_script
//
//  Runs a single user script against a single input string and prints the result as JSON.
//
//  Protocol
//    stdin:  {"code": "<javascript source>", "input": "<text>"}
//    stdout: {"results": ["...", "..."]} or {"error": "<message>", "code": "<stable-key>"}
//
//  A script has to define a global function `main(text)` and may return either a single string or an
//  array of strings. Every returned string becomes one candidate on the result page.
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

static void kayokoEmitResults(NSArray<NSString *> *results) {
    kayokoEmitPayload(@{@"results" : results ?: @[]});
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

static NSArray<NSString *> *kayokoNormalizeResult(JSValue *value,
                                                  NSUInteger maxResults,
                                                  NSUInteger maxResultLength,
                                                  NSUInteger maxTotalLength,
                                                  NSString **errorCode,
                                                  NSString **errorMessage,
                                                  NSDictionary<NSString *, id> **errorExtra) {
    if (!value || [value isUndefined] || [value isNull]) {
        return @[];
    }

    if ([value isString]) {
        NSString *text = [value toString];
        if ([text length] == 0) {
            return @[];
        }
        if ([text length] > maxResultLength) {
            *errorCode = @"result-too-large";
            *errorMessage = @"Result is too large";
            *errorExtra = @{
                @"stage" : @"run",
                @"length" : @([text length]),
                @"limit" : @(maxResultLength),
            };
            return nil;
        }
        return @[ text ];
    }

    if (![value isArray]) {
        *errorCode = @"bad-result-type";
        *errorMessage = @"Expected text or a list of texts";
        *errorExtra = @{@"stage" : @"run", @"type" : kayokoDescribeType(value)};
        return nil;
    }

    JSValue *lengthValue = [value valueForProperty:@"length"];
    NSUInteger length = [lengthValue isUndefined] ? 0 : [lengthValue toUInt32];
    NSMutableArray<NSString *> *results = [NSMutableArray arrayWithCapacity:MIN(length, maxResults)];
    NSUInteger totalLength = 0;

    for (NSUInteger index = 0; index < length; index++) {
        if ([results count] >= maxResults) {
            *errorCode = @"too-many-results";
            *errorMessage = @"Too many results";
            *errorExtra = @{
                @"stage" : @"run",
                @"count" : @([results count]),
                @"limit" : @(maxResults),
            };
            return nil;
        }

        JSValue *element = [value valueAtIndex:index];
        if (![element isString]) {
            *errorCode = @"bad-result-type";
            *errorMessage = @"Expected text or a list of texts";
            *errorExtra = @{
                @"stage" : @"run",
                @"type" : kayokoDescribeType(element),
                @"index" : @(index + 1),
            };
            return nil;
        }

        NSString *text = [element toString];
        if ([text length] == 0) {
            continue;
        }
        if ([text length] > maxResultLength) {
            *errorCode = @"result-too-large";
            *errorMessage = @"Result is too large";
            *errorExtra = @{
                @"stage" : @"run",
                @"index" : @(index + 1),
                @"length" : @([text length]),
                @"limit" : @(maxResultLength),
            };
            return nil;
        }

        totalLength += [text length];
        if (totalLength > maxTotalLength) {
            *errorCode = @"result-too-large";
            *errorMessage = @"Too much text in total";
            *errorExtra = @{
                @"stage" : @"run",
                @"length" : @(totalLength),
                @"limit" : @(maxTotalLength),
            };
            return nil;
        }

        [results addObject:text];
    }

    return results;
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

static NSArray<NSString *> *kayokoRunScript(NSString *code,
                                            NSString *input,
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

    // Scripts only get a console shim; there is no filesystem, network or host bridge available to them.
    [context evaluateScript:@"var console = {"
                              @"  log: function () { __kayokoLog(Array.prototype.slice.call(arguments).map(String).join(' ')); },"
                              @"  info: function () { console.log.apply(console, arguments); },"
                              @"  warn: function () { console.log.apply(console, arguments); },"
                              @"  error: function () { console.log.apply(console, arguments); },"
                              @"  debug: function () { console.log.apply(console, arguments); }"
                              @"};"];

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

    return kayokoNormalizeResult(value, maxResults, maxResultLength, maxTotalLength, errorCode, errorMessage, errorExtra);
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

        pthread_t watchdog = (pthread_t)0;
        if (pthread_create(&watchdog, NULL, kayokoWatchdogMain, &timeout) == 0) {
            pthread_detach(watchdog);
        }

        NSString *errorCode = nil;
        NSString *errorMessage = nil;
        NSDictionary<NSString *, id> *errorExtra = nil;
        NSArray<NSString *> *results = kayokoRunScript(code, text, maxResults, maxResultLength, maxTotalLength,
                                                      &errorCode, &errorMessage, &errorExtra);
        if (!results) {
            kayokoEmitError(errorCode, errorMessage, errorExtra);
            return 1;
        }

        kayokoEmitResults(results);
        return 0;
    }
}
