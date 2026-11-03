//
//  KayokoScriptRunner.m
//  Kayoko
//

#import "KayokoScriptRunner.h"

#import "KayokoScript.h"

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
          completion(nil, @"missing-executor", @"Script runner is unavailable");
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
          completion(nil, @"invalid-request", @"Request is empty");
        });
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSArray<NSString *> *results = nil;
      NSString *errorCode = nil;
      NSString *errorMessage = nil;
      [self executeAtPath:executorPath
              requestData:requestData
                  results:&results
                errorCode:&errorCode
              errorMessage:&errorMessage];

      dispatch_async(dispatch_get_main_queue(), ^{
        completion(results, errorCode, errorMessage);
      });
    });
}

#pragma mark - Process

- (void)executeAtPath:(NSString *)executorPath
          requestData:(NSData *)requestData
              results:(NSArray<NSString *> **)results
            errorCode:(NSString *__autoreleasing *)errorCode
          errorMessage:(NSString *__autoreleasing *)errorMessage {
    int stdinPipe[2] = {-1, -1};
    int stdoutPipe[2] = {-1, -1};
    if (pipe(stdinPipe) != 0 || pipe(stdoutPipe) != 0) {
        *errorCode = @"runner-failed";
        *errorMessage = @"Unable to create pipes";
        return;
    }

    posix_spawn_file_actions_t fileActions;
    posix_spawn_file_actions_init(&fileActions);
    posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&fileActions, stdinPipe[0]);
    posix_spawn_file_actions_addclose(&fileActions, stdinPipe[1]);
    posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0]);
    posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[1]);
    // Script logging is diagnostics only; discarding it keeps the pipe from filling up.
    posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

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
        *errorCode = @"spawn-failed";
        *errorMessage = [NSString stringWithFormat:@"Unable to start script runner (%d)", spawnResult];
        return;
    }

    close(stdinPipe[0]);
    close(stdoutPipe[1]);

    // The child reads stdin before writing anything, so feeding it from another queue avoids a pipe deadlock
    // when the input text is larger than the pipe buffer. C arrays cannot be captured by a block, hence the copy.
    int stdinWriteDescriptor = stdinPipe[1];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      kayokoScriptWriteAll(stdinWriteDescriptor, requestData);
      close(stdinWriteDescriptor);
    });

    NSMutableData *output = [NSMutableData data];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kKayokoScriptRunnerTimeout];
    BOOL timedOut = NO;
    BOOL outputExceededLimit = NO;
    uint8_t buffer[4096];

    while (YES) {
        NSTimeInterval remaining = [deadline timeIntervalSinceNow];
        if (remaining <= 0) {
            timedOut = YES;
            kill(processIdentifier, SIGKILL);
            break;
        }

        struct pollfd descriptor = {
            .fd = stdoutPipe[0],
            .events = POLLIN,
            .revents = 0,
        };
        int pollResult = poll(&descriptor, 1, (int)(MIN(remaining, 1.0) * 1000));
        if (pollResult < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (pollResult == 0) {
            continue;
        }

        ssize_t count = read(stdoutPipe[0], buffer, sizeof(buffer));
        if (count > 0) {
            [output appendBytes:buffer length:(NSUInteger)count];
            if ([output length] > kKayokoScriptRunnerMaximumOutputBytes) {
                outputExceededLimit = YES;
                kill(processIdentifier, SIGKILL);
                break;
            }
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        break;
    }

    close(stdoutPipe[0]);
    int status = 0;
    waitpid(processIdentifier, &status, 0);

    if (timedOut) {
        *errorCode = @"timeout";
        *errorMessage = @"Script timed out";
        return;
    }
    if (outputExceededLimit) {
        *errorCode = @"result-too-large";
        *errorMessage = @"Result is too large";
        return;
    }

    NSDictionary *response = [NSJSONSerialization JSONObjectWithData:output options:0 error:NULL];
    if (![response isKindOfClass:[NSDictionary class]]) {
        *errorCode = @"runner-failed";
        *errorMessage = @"Script runner stopped unexpectedly";
        return;
    }

    id reportedError = [response objectForKey:@"error"];
    if ([reportedError isKindOfClass:[NSString class]] && [reportedError length] > 0) {
        id reportedCode = [response objectForKey:@"code"];
        *errorCode = [reportedCode isKindOfClass:[NSString class]] ? reportedCode : @"failure";
        *errorMessage = reportedError;
        return;
    }

    id rawResults = [response objectForKey:@"results"];
    if (![rawResults isKindOfClass:[NSArray class]]) {
        *errorCode = @"runner-failed";
        *errorMessage = @"Script runner returned an unexpected response";
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
