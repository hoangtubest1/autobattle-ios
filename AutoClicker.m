// AutoClicker.m
// Standalone iOS Auto-Clicker - Inject via TrollFools
// No Substrate / ElleKit / KIF required
// Unity-compatible: uses IOHIDEvent (hardware-level touch simulation)
//
// UI: Floating blue button (draggable)
//   - Drag button ON TOP of "Trận đánh" button
//   - Single tap = START auto-click (button turns red)
//   - Single tap again = STOP
//   - Long press (1s) = set click target to button's position, then drag button away

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>

// ─── Private IOHIDEvent API ──────────────────────────────────────────────────

typedef struct __IOHIDEvent *IOHIDEventRef;

typedef IOHIDEventRef (*FN_CreateFingerEvent)(
    CFAllocatorRef allocator,
    uint64_t       timeStamp,
    uint32_t       index,
    uint32_t       identity,
    uint32_t       eventMask,
    double x, double y, double z,
    double tipPressure,
    double twistAngle,
    double minorRadius,
    double majorRadius,
    double quality,
    double density,
    double irregularity,
    uint32_t buttonMask,
    uint32_t options
);

static FN_CreateFingerEvent  gCreateFingerEvent = NULL;
static BOOL                  gIOHIDLoaded       = NO;

// IOHIDDigitizerEventMask
#define kHIDRange    (1 << 0)
#define kHIDTouch    (1 << 1)
#define kHIDPosition (1 << 2)

static void loadIOHID(void) {
    if (gIOHIDLoaded) return;
    gIOHIDLoaded = YES;
    const char *paths[] = {
        "/System/Library/Frameworks/IOKit.framework/IOKit",
        "/usr/lib/libIOKit.dylib",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        void *h = dlopen(paths[i], RTLD_LAZY | RTLD_GLOBAL);
        if (h) {
            gCreateFingerEvent = (FN_CreateFingerEvent)
                dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
            if (gCreateFingerEvent) {
                NSLog(@"[AutoClicker] IOHIDEventCreateDigitizerFingerEvent loaded OK");
                break;
            }
        }
    }
    if (!gCreateFingerEvent)
        NSLog(@"[AutoClicker] WARNING: IOHIDEventCreateDigitizerFingerEvent not found");
}

// ─── Send a hardware-level tap ───────────────────────────────────────────────

static void sendHIDTap(CGPoint point) {
    loadIOHID();
    if (!gCreateFingerEvent) return;

    // Find game window (non-key-window approach: our overlay is not key,
    // so game window stays key and receives HID events)
    UIWindow *gameWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { gameWindow = w; break; }
    }
    if (!gameWindow) return;

    CGRect bounds = gameWindow.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;

    double normX = point.x / bounds.size.width;
    double normY = point.y / bounds.size.height;
    uint64_t ts  = mach_absolute_time();

    // Touch DOWN
    IOHIDEventRef down = gCreateFingerEvent(
        kCFAllocatorDefault, ts,
        0, 1,                               // finger index=0, identity=1
        kHIDRange | kHIDTouch | kHIDPosition,
        normX, normY, 0.0,                  // x, y, z
        1.0, 0.0,                           // tipPressure, twistAngle
        3.0, 3.0,                           // minorRadius, majorRadius
        1.0, 1.0, 0.1,                      // quality, density, irregularity
        0, 0                                // buttonMask, options
    );

    UIApplication *app = [UIApplication sharedApplication];
    SEL enqueue = NSSelectorFromString(@"_enqueueHIDEvent:");

    if (down && [app respondsToSelector:enqueue]) {
        NSMethodSignature *sig = [app methodSignatureForSelector:enqueue];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:app];
        [inv setSelector:enqueue];
        [inv setArgument:&down atIndex:2];
        [inv invoke];
    }
    if (down) CFRelease(down);

    // Touch UP after 80 ms
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        uint64_t ts2 = mach_absolute_time();
        IOHIDEventRef up = gCreateFingerEvent(
            kCFAllocatorDefault, ts2,
            0, 1,
            kHIDRange | kHIDPosition,       // no kHIDTouch → finger lifted
            normX, normY, 0.0,
            0.0, 0.0,
            3.0, 3.0,
            1.0, 1.0, 0.1,
            0, 0
        );
        if (up && [app respondsToSelector:enqueue]) {
            NSMethodSignature *sig = [app methodSignatureForSelector:enqueue];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:app];
            [inv setSelector:enqueue];
            [inv setArgument:&up atIndex:2];
            [inv invoke];
        }
        if (up) CFRelease(up);
    });
}

// ─── Passthrough Window & View ───────────────────────────────────────────────
// Cho phép touch xuyên qua vùng trống, chỉ giữ lại touch trên button/dot

@interface PassthroughView : UIView
@end
@implementation PassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // Nếu hit vào chính view nền → trả nil để touch xuyên xuống game
    return (hit == self) ? nil : hit;
}
@end

@interface PassthroughWindow : UIWindow
@end
@implementation PassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // Nếu không có subview nào bắt touch → cho game xử lý
    return (hit == self) ? nil : hit;
}
@end

// ─── Floating UI Controller ──────────────────────────────────────────────────

@interface ACController : NSObject
@property (nonatomic) BOOL      isRunning;
@property (nonatomic) CGPoint   clickTarget;   // where to click
@property (nonatomic) BOOL      settingTarget; // long-press mode
@property (nonatomic, strong) NSTimer      *timer;
@property (nonatomic, strong) UIWindow     *overlayWindow;
@property (nonatomic, strong) UIButton     *controlBtn;
@property (nonatomic, strong) UIView       *targetDot;  // red dot showing click spot
+ (instancetype)shared;
- (void)setup;
@end

@implementation ACController

+ (instancetype)shared {
    static ACController *inst;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ inst = [ACController new]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Default click position: center-bottom area (common for battle buttons)
        CGSize screen = [UIScreen mainScreen].bounds.size;
        _clickTarget  = CGPointMake(screen.width * 0.5, screen.height * 0.78);
    }
    return self;
}

- (void)setup {
    // ── Create overlay window ──
    PassthroughWindow *win;
    UIWindowScene *activeScene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            activeScene = (UIWindowScene *)s;
            break;
        }
    }
    if (activeScene)
        win = [[PassthroughWindow alloc] initWithWindowScene:activeScene];
    else
        win = [[PassthroughWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

    win.windowLevel            = UIWindowLevelAlert + 500;
    win.backgroundColor        = UIColor.clearColor;
    win.userInteractionEnabled = YES;
    // KHÔNG makeKeyAndVisible → game window giữ key → nhận HID events
    win.hidden = NO;
    self.overlayWindow = win;

    UIViewController *vc = [UIViewController new];
    // Dùng PassthroughView để touch vùng trống xuyên qua game
    PassthroughView *rootView = [[PassthroughView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    rootView.backgroundColor = UIColor.clearColor;
    vc.view = rootView;
    win.rootViewController = vc;

    // ── Control button ──
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(20, 120, 56, 56);
    [self styleButton:btn running:NO];
    [btn setTitle:@"▶" forState:UIControlStateNormal];
    [btn addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    lp.minimumPressDuration = 0.8;
    [btn addGestureRecognizer:lp];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [btn addGestureRecognizer:pan];

    self.controlBtn = btn;
    [vc.view addSubview:btn];

    // ── Target dot (shows where the click will land) ──
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 18, 18)];
    dot.center          = self.clickTarget;
    dot.backgroundColor = [UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:0.75];
    dot.layer.cornerRadius = 9;
    dot.layer.borderColor  = UIColor.whiteColor.CGColor;
    dot.layer.borderWidth  = 1.5;
    dot.userInteractionEnabled = NO;
    self.targetDot = dot;
    [vc.view addSubview:dot];

    NSLog(@"[AutoClicker] UI ready. Target: (%.0f, %.0f)", self.clickTarget.x, self.clickTarget.y);
}

- (void)styleButton:(UIButton *)btn running:(BOOL)running {
    btn.layer.cornerRadius  = 28;
    btn.layer.borderWidth   = 2;
    btn.layer.borderColor   = UIColor.whiteColor.CGColor;
    btn.layer.shadowColor   = UIColor.blackColor.CGColor;
    btn.layer.shadowOffset  = CGSizeMake(0, 2);
    btn.layer.shadowOpacity = 0.45;
    btn.layer.shadowRadius  = 5;
    btn.titleLabel.font     = [UIFont systemFontOfSize:20];
    [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    if (running)
        btn.backgroundColor = [UIColor colorWithRed:0.9 green:0.25 blue:0.25 alpha:0.92];
    else
        btn.backgroundColor = [UIColor colorWithRed:0.15 green:0.55 blue:1.0 alpha:0.92];
}

- (void)onTap {
    if (self.settingTarget) {
        // Cancel target-setting mode
        self.settingTarget = NO;
        [self.controlBtn setTitle:@"▶" forState:UIControlStateNormal];
        [self styleButton:self.controlBtn running:NO];
        return;
    }
    self.isRunning = !self.isRunning;
    if (self.isRunning) {
        [self.controlBtn setTitle:@"⏹" forState:UIControlStateNormal];
        [self styleButton:self.controlBtn running:YES];
        self.timer = [NSTimer scheduledTimerWithTimeInterval:1.2
                                                      target:self
                                                    selector:@selector(doClick)
                                                    userInfo:nil
                                                     repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
        NSLog(@"[AutoClicker] ▶ Started — clicking at (%.0f, %.0f)", self.clickTarget.x, self.clickTarget.y);
    } else {
        [self.controlBtn setTitle:@"▶" forState:UIControlStateNormal];
        [self styleButton:self.controlBtn running:NO];
        [self.timer invalidate];
        self.timer = nil;
        NSLog(@"[AutoClicker] ⏹ Stopped");
    }
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    // Set click target = current button center
    CGPoint btnCenter = self.controlBtn.center;
    self.clickTarget  = btnCenter;
    self.targetDot.center = btnCenter;

    // Flash feedback
    [UIView animateWithDuration:0.15 animations:^{
        self.controlBtn.transform = CGAffineTransformMakeScale(1.3, 1.3);
    } completion:^(BOOL f) {
        [UIView animateWithDuration:0.15 animations:^{
            self.controlBtn.transform = CGAffineTransformIdentity;
        }];
    }];

    NSLog(@"[AutoClicker] 🎯 Target set to (%.0f, %.0f)", btnCenter.x, btnCenter.y);
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint delta = [g translationInView:g.view.superview];
    CGPoint c     = g.view.center;
    c.x += delta.x;
    c.y += delta.y;
    g.view.center = c;
    [g setTranslation:CGPointZero inView:g.view.superview];
}

- (void)doClick {
    sendHIDTap(self.clickTarget);
}

@end

// ─── Entry point ─────────────────────────────────────────────────────────────

__attribute__((constructor))
static void acInit(void) {
    NSLog(@"[AutoClicker] Dylib loaded!");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[ACController shared] setup];
    });
}
