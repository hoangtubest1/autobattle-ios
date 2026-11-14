#import <UIKit/UIKit.h>

@interface AutoBattleClicker : NSObject
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) UIButton *toggleBtn;
@property (nonatomic, assign) BOOL isRunning;
+ (instancetype)sharedInstance;
- (void)setupFloatingButton;
@end

@implementation AutoBattleClicker

+ (instancetype)sharedInstance {
    static AutoBattleClicker *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AutoBattleClicker alloc] init];
    });
    return instance;
}

+ (void)load {
    // Chờ 3 giây sau khi game khởi động để nạp nút bấm nổi
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[AutoBattleClicker sharedInstance] setupFloatingButton];
    });
}

- (void)setupFloatingButton {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in scene.windows) {
                    if (w.isKeyWindow) {
                        window = w;
                        break;
                    }
                }
            }
        }
    }
    if (!window) {
        window = [UIApplication sharedApplication].keyWindow;
    }
    if (!window) return;

    // Tạo nút bấm nổi điều khiển Auto
    self.toggleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.toggleBtn.frame = CGRectMake(20, 220, 75, 36);
    self.toggleBtn.backgroundColor = [UIColor colorWithRed:0.1 green:0.7 blue:0.2 alpha:0.9];
    [self.toggleBtn setTitle:@"AUTO" forState:UIControlStateNormal];
    [self.toggleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.toggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    self.toggleBtn.layer.cornerRadius = 18;
    self.toggleBtn.layer.borderWidth = 1.5;
    self.toggleBtn.layer.borderColor = [UIColor whiteColor].CGColor;
    self.toggleBtn.clipsToBounds = YES;

    // Kéo thả nút bấm trên màn hình
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.toggleBtn addGestureRecognizer:pan];

    [self.toggleBtn addTarget:self action:@selector(toggleClick) forControlEvents:UIControlEventTouchUpInside];
    [window addSubview:self.toggleBtn];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    CGPoint translation = [pan translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:btn.superview];
}

- (void)toggleClick {
    self.isRunning = !self.isRunning;
    if (self.isRunning) {
        [self.toggleBtn setTitle:@"STOP" forState:UIControlStateNormal];
        self.toggleBtn.backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:0.9];

        // Tự động gõ liên tục vào nút "Trận đánh" (mỗi 0.4 giây một lần)
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer * _Nonnull t) {
            CGSize size = [UIScreen mainScreen].bounds.size;
            // Vị trí nút Trận đánh ở góc dưới bên phải
            CGPoint target = CGPointMake(size.width - 65, size.height - 45);

            UIWindow *win = [UIApplication sharedApplication].keyWindow;
            UIView *view = [win hitTest:target withEvent:nil];

            if ([view isKindOfClass:[UIControl class]]) {
                [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
            } else if (view.superview && [view.superview isKindOfClass:[UIControl class]]) {
                [(UIControl *)view.superview sendActionsForControlEvents:UIControlEventTouchUpInside];
            }
        }];
    } else {
        [self.toggleBtn setTitle:@"AUTO" forState:UIControlStateNormal];
        self.toggleBtn.backgroundColor = [UIColor colorWithRed:0.1 green:0.7 blue:0.2 alpha:0.9];
        [self.timer invalidate];
        self.timer = nil;
    }
}

@end
