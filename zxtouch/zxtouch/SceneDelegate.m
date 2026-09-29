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

- (BOOL)darkModeEnabled {
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:SPRINGBOARD_CONFIG_PATH];
    id configValue = config[@"dark_mode"];
    if (configValue) {
        BOOL dark = [configValue boolValue];
        [[NSUserDefaults standardUserDefaults] setBool:dark forKey:@"dark_mode"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        return dark;
    }
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"dark_mode"];
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    // Apply saved dark mode preference when the window is ready
    BOOL darkMode = [self darkModeEnabled];
    UIUserInterfaceStyle style = darkMode ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
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
