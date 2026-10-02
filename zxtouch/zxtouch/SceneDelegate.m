//
//  SceneDelegate.m
//  zxtouch
//
//  Created by Jason on 2020/12/10.
//

#import "SceneDelegate.h"
#import "Config.h"

@interface SceneDelegate ()

@end

@implementation SceneDelegate

// 界面外观：直接存 UIUserInterfaceStyle（0跟随系统 1浅色 2深色）
- (UIUserInterfaceStyle)appearanceMode {
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:SPRINGBOARD_CONFIG_PATH];
    id configValue = config[@"appearance_mode"];
    if (!configValue) {
        // 旧版本只有「深色模式」开关，迁移成 深色/浅色 两档
        id legacyValue = config[@"dark_mode"];
        BOOL dark = legacyValue ? [legacyValue boolValue]
                                : [[NSUserDefaults standardUserDefaults] boolForKey:@"dark_mode"];
        configValue = @(dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight);
    }
    NSInteger mode = [configValue integerValue];
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:@"appearance_mode"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    return (UIUserInterfaceStyle)mode;
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    // Apply saved appearance preference when the window is ready
    UIUserInterfaceStyle style = [self appearanceMode];
    if ([scene isKindOfClass:[UIWindowScene class]]) {
        for (UIWindow *win in ((UIWindowScene *)scene).windows) {
            win.overrideUserInterfaceStyle = style;
        }
    }
    // Also apply to the SceneDelegate window once it's created
    dispatch_async(dispatch_get_main_queue(), ^{
        self.window.overrideUserInterfaceStyle = style;
    });
}


- (void)sceneDidDisconnect:(UIScene *)scene {
    // Called as the scene is being released by the system.
    // This occurs shortly after the scene enters the background, or when its session is discarded.
    // Release any resources associated with this scene that can be re-created the next time the scene connects.
    // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
}


- (void)sceneDidBecomeActive:(UIScene *)scene {
    // Called when the scene has moved from an inactive state to an active state.
    // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
}


- (void)sceneWillResignActive:(UIScene *)scene {
    // Called when the scene will move from an active state to an inactive state.
    // This may occur due to temporary interruptions (ex. an incoming phone call).
}


- (void)sceneWillEnterForeground:(UIScene *)scene {
    // Called as the scene transitions from the background to the foreground.
    // Use this method to undo the changes made on entering the background.
}


- (void)sceneDidEnterBackground:(UIScene *)scene {
    // Called as the scene transitions from the foreground to the background.
    // Use this method to save data, release shared resources, and store enough scene-specific state information
    // to restore the scene back to its current state.
}


@end
