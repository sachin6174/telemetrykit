#import "TKAppDelegate.h"

#import "TKDemoTelemetry.h"
#import "TKViewController.h"

@implementation TKAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    TKViewController *viewController = [[TKViewController alloc] init];
    self.window.rootViewController =
        [[UINavigationController alloc] initWithRootViewController:viewController];
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [[TKDemoTelemetry shared] flushWithCompletion:^(NSError * _Nullable error) {
        if (error != nil) {
            NSLog(@"Telemetry background flush did not complete: %@", error.localizedDescription);
        }
    }];
}

@end
