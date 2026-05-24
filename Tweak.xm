#import <UIKit/UIKit.h>
#import <unistd.h>
#import <pthread.h>
#import <objc/runtime.h>
#import <fcntl.h>

#define PrivClass(x) (NSClassFromString(@#x) ?: NSClassFromString(@"LiveContainer." #x))

static NSString *getSharedLogPath() {
    Class LCSharedUtils = PrivClass(LCSharedUtils);
    NSString *appGroup = @"com.kdt.livecontainer"; 
    if (LCSharedUtils) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        appGroup = [LCSharedUtils performSelector:NSSelectorFromString(@"appGroupID")];
        #pragma clang diagnostic pop
    }
    NSURL *groupURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:appGroup];
    return [[groupURL path] stringByAppendingPathComponent:@"LCConsole.log"];
}

@interface ConsoleWindow : UIWindow
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) NSTimer *clearTimer;
@property (nonatomic, assign) long long lastReadOffset;
+ (instancetype)sharedInstance;
- (void)addLog:(NSString *)text;
- (void)tailLogs;
@end



@implementation ConsoleWindow
+ (instancetype)sharedInstance {
    static ConsoleWindow *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] initWithFrame:CGRectMake(5, 40, [UIScreen mainScreen].bounds.size.width - 10, 300)];
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                shared.windowScene = (UIWindowScene *)scene;
                break;
            }
        }
        shared.lastReadOffset = 0;
        [NSTimer scheduledTimerWithTimeInterval:0.5 target:shared selector:@selector(tailLogs) userInfo:nil repeats:YES];
    });
    return shared;
}
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelStatusBar + 100;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        _textView = [[UITextView alloc] initWithFrame:self.bounds];
        _textView.backgroundColor = [UIColor clearColor];
        _textView.textColor = [UIColor whiteColor];
        _textView.font = [UIFont fontWithName:@"Menlo-Bold" size:9];
        _textView.editable = NO;
        _textView.selectable = NO;
        _textView.userInteractionEnabled = NO;
        [_textView setContentInset:UIEdgeInsetsZero];
        [self addSubview:_textView];

        self.hidden = NO;
    }
    return self;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}
- (BOOL)_ignoresHitTest {
    return YES;
}
- (void)clearText {
    [UIView transitionWithView:self.textView duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        self.textView.text = @"";
    } completion:nil];
}
- (void)addLog:(NSString *)text {
    if (!text || text.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *currentText = self.textView.text ?: @"";
        NSString *newText = [currentText stringByAppendingString:text];
        
        NSArray *lines = [newText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        if (lines.count > 15) {
            lines = [lines subarrayWithRange:NSMakeRange(lines.count - 15, 15)];
            newText = [lines componentsJoinedByString:@"\n"];
        }
        
        self.textView.text = newText;
        [self.textView scrollRangeToVisible:NSMakeRange(self.textView.text.length, 0)];
        
        [self.clearTimer invalidate];
        self.clearTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(clearText) userInfo:nil repeats:NO];
    });
}
- (void)tailLogs {
    NSString *logPath = getSharedLogPath();
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:logPath];
    if (!file) return;
    
    [file seekToFileOffset:self.lastReadOffset];
    NSData *data = [file readDataToEndOfFile];
    if (data.length > 0) {
        NSString *newLogs = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!newLogs) newLogs = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
        if (newLogs) {
            [self addLog:newLogs];
        }
        self.lastReadOffset = [file offsetInFile];
    }
    [file closeFile];
}
@end

static void startCapture(void) {
    int pipefd[2];
    if (pipe(pipefd) == -1) return;

    int readFd = pipefd[0];
    int writeFd = pipefd[1];
    dup2(writeFd, STDERR_FILENO); // エラー出力
    dup2(writeFd, STDOUT_FILENO); // 標準出力
    
    NSString *processName = [[NSProcessInfo processInfo] processName];
    NSString *tag = [NSString stringWithFormat:@"[%@] ", processName];
    NSString *logPath = getSharedLogPath();

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char buffer[1024];
        while (YES) {
            ssize_t size = read(readFd, buffer, sizeof(buffer) - 1);
            if (size > 0) {
                buffer[size] = '\0';
                NSString *rawLog = [NSString stringWithCString:buffer encoding:NSUTF8StringEncoding];
                if (!rawLog) rawLog = [NSString stringWithCString:buffer encoding:NSASCIIStringEncoding];
                if (!rawLog) continue;
                
                NSString *taggedLog = [tag stringByAppendingString:rawLog];
                NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:logPath];
                if (!file) {
                    [taggedLog writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                } else {
                    [file seekToEndOfFile];
                    [file writeData:[taggedLog dataUsingEncoding:NSUTF8StringEncoding]];
                    [file closeFile];
                }
            }
        }
    });
}

%ctor {
    @autoreleasepool {
        BOOL isHost = (PrivClass(LCUtils) != nil);
        NSString *procName = [[NSProcessInfo processInfo] processName] ?: @"unknown";
        if (isHost) {
            NSString *logPath = getSharedLogPath();
            [@"" writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[ConsoleWindow sharedInstance] addLog:@"[Console] Host UI Ready.\n"];
                startCapture();
            });
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                startCapture();
                NSString *msg = [NSString stringWithFormat:@"[Console] Guest %@ connected.\n", procName];
                NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:getSharedLogPath()];
                if (file) {
                    [file seekToEndOfFile];
                    [file writeData:[msg dataUsingEncoding:NSUTF8StringEncoding]];
                    [file closeFile];
                }
            });
        }
    }
}
