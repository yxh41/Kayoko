//
//  KayokoScriptRunner.m
//  Kayoko
//

#import "KayokoScriptRunner.h"

#import "KayokoScript.h"
#import "KayokoScriptFailure.h"

#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <signal.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

#import <roothide.h>

static NSString *const kKayokoScriptExecutorName = @"kayoko_script";
static NSTimeInterval const kKayokoScriptRunnerTimeout = 6.0;
static NSTimeInterval const kKayokoScriptRunnerExecutorTimeout = 5.0;
static NSUInteger const kKayokoScriptRunnerMaximumOutputBytes = 4 * 1024 * 1024;
/// console.log is a debug aid, not a result: keep the tail of it and drop the rest rather than let a chatty
/// script fill memory (or block on a full pipe once this side stops reading).
static NSUInteger const kKayokoScriptRunnerMaximumLogBytes = 32 * 1024;
static NSUInteger const kKayokoScriptRunnerMaximumLogLines = 40;

extern char **environ;

NS_ASSUME_NONNULL_BEGIN

static BOOL kayokoScriptWriteAll(int descriptor, NSData *data) {
    const uint8_t *bytes = [data bytes];
    NSUInteger totalLength = [data length];
    NSUInteger offset = 0;

    while (offset < totalLength) {
        ssize_t written = write(descriptor, bytes + offset, totalLength - offset);
        if (written > 0) {
            offset += (NSUInteger)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        return NO;
    }

    return YES;
}

/// console.log arrives as raw stderr. Keep it as lines, drop the blank ones, and hold on to the tail only:
/// the interesting part of a crash log is always the end of it.
static NSArray<NSString *> *kayokoScriptLogLines(NSData *data, BOOL truncated) {
    if ([data length] == 0) {
        return @[];
    }

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if ([text length] == 0) {
        return @[];
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        if ([trimmed length] > 0) {
            [lines addObject:trimmed];
        }
    }

    if (truncated && [lines count] > 0) {
        [lines insertObject:@"…" atIndex:0];
    }

    if ([lines count] > kKayokoScriptRunnerMaximumLogLines) {
        return [lines subarrayWithRange:NSMakeRange([lines count] - kKayokoScriptRunnerMaximumLogLines,
                                                    kKayokoScriptRunnerMaximumLogLines)];
    }

    return lines;
}

@implementation KayokoScriptRunner

+ (nullable NSString *)executorPath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSString *> *candidatePaths = @[
        jbroot([@"/usr/local/libexec" stringByAppendingPathComponent:kKayokoScriptExecutorName]),
        [@"/var/jb/usr/local/libexec" stringByAppendingPathComponent:kKayokoScriptExecutorName],
        [@"/usr/local/libexec" stringByAppendingPathComponent:kKayokoScriptExecutorName]
    ];
    for (NSString *path in candidatePaths) {
        if ([fileManager isExecutableFileAtPath:path]) {
            return path;
        }
    }

    return nil;
}

- (void)runScript:(KayokoScript *)script
            input:(NSString *)input
       completion:(KayokoScriptRunnerCompletion)completion {
    if (!completion) {
        return;
    }

    NSString *executorPath = [[self class] executorPath];
    if ([executorPath length] == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
          completion(nil, [KayokoScriptFailure failureWithCode:@"missing-executor"
                                                       message:@"Script runner is unavailable"]);
        });
        return;
    }

    NSDictionary *request = @{
        @"code" : [script code] ?: @"",
        @"input" : input ?: @"",
    };
    NSData *requestData = [NSJSONSerialization dataWithJSONObject:request options:0 error:NULL];
    if ([requestData length] == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
          completion(nil, [KayokoScriptFailure failureWithCode:@"invalid-request" message:@"Request is empty"]);
        });
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSArray<NSString *> *results = nil;
      KayokoScriptFailure *failure = nil;
      [self executeAtPath:executorPath requestData:requestData results:&results failure:&failure];

      dispatch_async(dispatch_get_main_queue(), ^{
        completion(results, failure);
      });
    });
}

#pragma mark - Process

- (void)executeAtPath:(NSString *)executorPath
          requestData:(NSData *)requestData
              results:(NSArray<NSString *> **)results
              failure:(KayokoScriptFailure **)failure {
    int stdinPipe[2] = {-1, -1};
    int stdoutPipe[2] = {-1, -1};
    int stderrPipe[2] = {-1, -1};
    if (pipe(stdinPipe) != 0 || pipe(stdoutPipe) != 0 || pipe(stderrPipe) != 0) {
        *failure = [KayokoScriptFailure failureWithCode:@"runner-failed" message:@"Unable to create pipes"];
        return;
    }

    posix_spawn_file_actions_t fileActions;
    posix_spawn_file_actions_init(&fileActions);
    posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO);
    // console.log lands on stderr, so it has to be carried back with the result: it is the only way a script
    // author can see what their own code did before it broke.
    posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&fileActions, stdinPipe[0]);
    posix_spawn_file_actions_addclose(&fileActions, stdinPipe[1]);
    posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0]);
    posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[1]);
    posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0]);
    posix_spawn_file_actions_addclose(&fileActions, stderrPipe[1]);

    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);

    NSString *timeoutArgument = [NSString stringWithFormat:@"%.1f", kKayokoScriptRunnerExecutorTimeout];
    char *argv[] = {
        (char *)[executorPath fileSystemRepresentation],
        (char *)"-t",
        (char *)[timeoutArgument UTF8String],
        NULL,
    };

    pid_t processIdentifier = 0;
    int spawnResult = posix_spawn(&processIdentifier, [executorPath fileSystemRepresentation], &fileActions,
                                  &attributes, argv, environ);
    posix_spawn_file_actions_destroy(&fileActions);
    posix_spawnattr_destroy(&attributes);

    if (spawnResult != 0) {
        close(stdinPipe[0]);
        close(stdinPipe[1]);
        close(stdoutPipe[0]);
        close(stdoutPipe[1]);
        close(stderrPipe[0]);
        close(stderrPipe[1]);
        *failure = [KayokoScriptFailure
            failureWithCode:@"spawn-failed"
                   message:[NSString stringWithFormat:@"Unable to start script runner (%d)", spawnResult]
                    fields:@{@"status" : @(spawnResult)}];
        return;
    }

    close(stdinPipe[0]);
    close(stdoutPipe[1]);
    close(stderrPipe[1]);

    // The child reads stdin before writing anything, so feeding it from another queue avoids a pipe deadlock
    // when the input text is larger than the pipe buffer. C arrays cannot be captured by a block, hence the copy.
    int stdinWriteDescriptor = stdinPipe[1];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      kayokoScriptWriteAll(stdinWriteDescriptor, requestData);
      close(stdinWriteDescriptor);
    });

    NSMutableData *output = [NSMutableData data];
    NSMutableData *logData = [NSMutableData data];
    BOOL logTruncated = NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kKayokoScriptRunnerTimeout];
    BOOL timedOut = NO;
    BOOL outputExceededLimit = NO;
    BOOL stdoutOpen = YES;
    BOOL stderrOpen = YES;
    uint8_t buffer[4096];

    while (stdoutOpen || stderrOpen) {
        NSTimeInterval remaining = [deadline timeIntervalSinceNow];
        if (remaining <= 0) {
            timedOut = YES;
            kill(processIdentifier, SIGKILL);
            break;
        }

        // Both streams are drained in the same loop: a script that logs more than a pipe buffer while this side
        // waits on stdout alone would stall until the watchdog killed it.
        struct pollfd descriptors[2] = {
            {.fd = stdoutOpen ? stdoutPipe[0] : -1, .events = POLLIN, .revents = 0},
            {.fd = stderrOpen ? stderrPipe[0] : -1, .events = POLLIN, .revents = 0},
        };
        int pollResult = poll(descriptors, 2, (int)(MIN(remaining, 1.0) * 1000));
        if (pollResult < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (pollResult == 0) {
            continue;
        }

        if (stdoutOpen && (descriptors[0].revents & (POLLIN | POLLHUP))) {
            ssize_t count = read(stdoutPipe[0], buffer, sizeof(buffer));
            if (count > 0) {
                [output appendBytes:buffer length:(NSUInteger)count];
                if ([output length] > kKayokoScriptRunnerMaximumOutputBytes) {
                    outputExceededLimit = YES;
                    kill(processIdentifier, SIGKILL);
                    break;
                }
            } else if (count == 0 || errno != EINTR) {
                stdoutOpen = NO;
            }
        }

        if (stderrOpen && (descriptors[1].revents & (POLLIN | POLLHUP))) {
            ssize_t count = read(stderrPipe[0], buffer, sizeof(buffer));
            if (count > 0) {
                if ([logData length] < kKayokoScriptRunnerMaximumLogBytes) {
                    NSUInteger room = kKayokoScriptRunnerMaximumLogBytes - [logData length];
                    [logData appendBytes:buffer length:MIN((NSUInteger)count, room)];
                } else {
                    logTruncated = YES;
                }
            } else if (count == 0 || errno != EINTR) {
                stderrOpen = NO;
            }
        }
    }

    close(stdoutPipe[0]);
    close(stderrPipe[0]);
    int status = 0;
    waitpid(processIdentifier, &status, 0);

    NSArray<NSString *> *logs = kayokoScriptLogLines(logData, logTruncated);

    if (timedOut) {
        *failure = [KayokoScriptFailure
            failureWithCode:@"timeout"
                   message:@"Script timed out"
                    fields:@{@"stage" : @"run", @"seconds" : @(kKayokoScriptRunnerExecutorTimeout)}
                      logs:logs];
        return;
    }
    if (outputExceededLimit) {
        *failure = [KayokoScriptFailure failureWithCode:@"result-too-large"
                                                message:@"Result is too large"
                                                 fields:@{@"stage" : @"run"}
                                                   logs:logs];
        return;
    }

    NSDictionary *response = [NSJSONSerialization JSONObjectWithData:output options:0 error:NULL];
    if (![response isKindOfClass:[NSDictionary class]]) {
        NSString *message = WIFSIGNALED(status)
                                ? [NSString stringWithFormat:@"Script runner was killed by signal %d",
                                                             WTERMSIG(status)]
                                : [NSString stringWithFormat:@"Script runner exited with status %d",
                                                             WIFEXITED(status) ? WEXITSTATUS(status) : -1];
        *failure = [KayokoScriptFailure failureWithCode:@"runner-failed"
                                                message:message
                                                 fields:@{@"status" : @(status)}
                                                   logs:logs];
        return;
    }

    id reportedError = [response objectForKey:@"error"];
    if ([reportedError isKindOfClass:[NSString class]] && [reportedError length] > 0) {
        *failure = [KayokoScriptFailure failureWithResponse:response logs:logs];
        return;
    }

    id rawResults = [response objectForKey:@"results"];
    if (![rawResults isKindOfClass:[NSArray class]]) {
        *failure = [KayokoScriptFailure failureWithCode:@"runner-failed"
                                                message:@"Script runner returned an unexpected response"
                                                 fields:nil
                                                   logs:logs];
        return;
    }

    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (id entry in (NSArray *)rawResults) {
        if ([entry isKindOfClass:[NSString class]] && [entry length] > 0) {
            [texts addObject:entry];
        }
    }

    *results = texts;
}

@end

NS_ASSUME_NONNULL_END
