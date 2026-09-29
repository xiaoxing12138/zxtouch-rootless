//
//  AdderPopOverViewController.h
//  zxtouch
//
//  Created by Jason on 2021/1/16.
//

#import <UIKit/UIKit.h>
#import "../ScriptListViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface AdderPopOverViewController : UIViewController<UIPopoverPresentationControllerDelegate, UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
- (IBAction)createFolderButtonClick:(id)sender;
- (IBAction)createScriptButtonClick:(id)sender;
- (IBAction)importFileButtonClick:(id)sender;
- (IBAction)importImageButtonClick:(id)sender;

- (void)setFolder:(NSString*)path;
- (void)setUpperLevelViewController:(ScriptListViewController*)vc;

@end

NS_ASSUME_NONNULL_END
