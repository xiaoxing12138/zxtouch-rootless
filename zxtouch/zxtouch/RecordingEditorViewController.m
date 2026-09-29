#import "RecordingEditorViewController.h"

#import <math.h>

#import "Socket.h"

@interface RecordingEditorViewController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, copy) NSString *scriptBundlePath;
@property(nonatomic, copy) NSString *rawFilePath;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *actions;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic) BOOL hasChanges;
@end

@implementation RecordingEditorViewController

- (instancetype)initWithScriptBundlePath:(NSString *)scriptBundlePath
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _scriptBundlePath = [scriptBundlePath copy];
        _actions = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = self.scriptBundlePath.lastPathComponent.stringByDeletingPathExtension;
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.allowsSelectionDuringEditing = YES;
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    UIBarButtonItem *play = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPlay target:self action:@selector(playRecording)];
    UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(showInsertActions:)];
    UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(saveRecording)];
    self.navigationItem.rightBarButtonItems = @[play, add, save, self.editButtonItem];
    [self loadRecording];
}

- (void)loadRecording
{
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[self.scriptBundlePath stringByAppendingPathComponent:@"info.plist"]];
    NSString *entry = [info[@"Entry"] isKindOfClass:[NSString class]] ? info[@"Entry"] : nil;
    self.rawFilePath = entry.length ? [self.scriptBundlePath stringByAppendingPathComponent:entry] : nil;
    NSString *content = self.rawFilePath ? [NSString stringWithContentsOfFile:self.rawFilePath encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!content) {
        [self showError:@"This recording does not have a readable raw entry file."];
        return;
    }

    for (NSString *line in [content componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *command = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (command.length == 0) continue;
        NSMutableDictionary *action = [self actionFromCommand:command];
        [self.actions addObject:action ?: [@{ @"kind": @"command", @"command": command } mutableCopy]];
    }
    [self.tableView reloadData];
}

- (NSMutableDictionary *)actionFromCommand:(NSString *)command
{
    if ([command hasPrefix:@"18"] && command.length > 2) {
        return [@{ @"kind": @"wait", @"microseconds": @([[command substringFromIndex:2] longLongValue]) } mutableCopy];
    }
    if ([command hasPrefix:@"10"] && command.length >= 16 && [[command substringWithRange:NSMakeRange(2, 1)] isEqualToString:@"1"]) {
        NSInteger type = [[command substringWithRange:NSMakeRange(3, 1)] integerValue];
        NSInteger finger = [[command substringWithRange:NSMakeRange(4, 2)] integerValue];
        CGFloat x = [[command substringWithRange:NSMakeRange(6, 5)] integerValue] / 10.0;
        CGFloat y = [[command substringWithRange:NSMakeRange(11, 5)] integerValue] / 10.0;
        return [@{ @"kind": @"touch", @"type": @(type), @"finger": @(finger), @"x": @(x), @"y": @(y) } mutableCopy];
    }
    if ([command hasPrefix:@"11"] && command.length > 2) {
        return [@{ @"kind": @"launch", @"bundle": [command substringFromIndex:2] } mutableCopy];
    }
    if ([command hasPrefix:@"22"] && command.length > 2) {
        NSArray *parts = [[command substringFromIndex:2] componentsSeparatedByString:@";;"];
        if (parts.count >= 3) {
            return [@{ @"kind": @"toast", @"type": parts[0], @"text": parts[1], @"duration": parts[2], @"position": parts.count > 3 ? parts[3] : @"0" } mutableCopy];
        }
    }
    return nil;
}

- (NSString *)commandFromAction:(NSDictionary *)action
{
    NSString *kind = action[@"kind"];
    if ([kind isEqualToString:@"wait"]) return [NSString stringWithFormat:@"18%lld", [action[@"microseconds"] longLongValue]];
    if ([kind isEqualToString:@"touch"]) {
        NSInteger type = [action[@"type"] integerValue];
        NSInteger finger = [action[@"finger"] integerValue];
        NSInteger x = MAX(0, MIN(99999, llround([action[@"x"] doubleValue] * 10.0)));
        NSInteger y = MAX(0, MIN(99999, llround([action[@"y"] doubleValue] * 10.0)));
        return [NSString stringWithFormat:@"101%ld%02ld%05ld%05ld", (long)type, (long)finger, (long)x, (long)y];
    }
    if ([kind isEqualToString:@"launch"]) return [@"11" stringByAppendingString:action[@"bundle"] ?: @""];
    if ([kind isEqualToString:@"toast"]) return [NSString stringWithFormat:@"22%@;;%@;;%@;;%@", action[@"type"] ?: @"3", action[@"text"] ?: @"", action[@"duration"] ?: @"2", action[@"position"] ?: @"0"];
    return action[@"command"] ?: @"";
}

- (NSString *)titleForAction:(NSDictionary *)action
{
    NSString *kind = action[@"kind"];
    if ([kind isEqualToString:@"wait"]) return [NSString stringWithFormat:@"Wait %.2f seconds", [action[@"microseconds"] doubleValue] / 1000000.0];
    if ([kind isEqualToString:@"touch"]) {
        NSArray *names = @[@"Touch Up", @"Touch Down", @"Touch Move"];
        NSInteger type = [action[@"type"] integerValue];
        NSString *name = type >= 0 && type < names.count ? names[type] : @"Touch";
        return [NSString stringWithFormat:@"%@  (%.0f, %.0f)", name, [action[@"x"] doubleValue], [action[@"y"] doubleValue]];
    }
    if ([kind isEqualToString:@"launch"]) return [NSString stringWithFormat:@"Launch %@", action[@"bundle"] ?: @""];
    if ([kind isEqualToString:@"toast"]) return [NSString stringWithFormat:@"Toast: %@", action[@"text"] ?: @""];
    return @"Custom Command";
}

- (NSString *)detailForAction:(NSDictionary *)action
{
    NSString *kind = action[@"kind"];
    if ([kind isEqualToString:@"touch"]) return [NSString stringWithFormat:@"Finger %@", action[@"finger"] ?: @"1"];
    if ([kind isEqualToString:@"toast"]) return [NSString stringWithFormat:@"%@ seconds", action[@"duration"] ?: @"2"];
    if ([kind isEqualToString:@"command"]) return action[@"command"] ?: @"";
    return @"";
}

- (void)markChanged
{
    self.hasChanges = YES;
    self.navigationItem.prompt = @"Unsaved changes";
}

- (void)saveRecording
{
    if (self.rawFilePath.length == 0) return;
    NSMutableArray<NSString *> *commands = [NSMutableArray arrayWithCapacity:self.actions.count];
    for (NSDictionary *action in self.actions) [commands addObject:[self commandFromAction:action]];
    NSError *error = nil;
    [[commands componentsJoinedByString:@"\n"] writeToFile:self.rawFilePath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (error) {
        [self showError:error.localizedDescription ?: @"Unable to save this recording."];
        return;
    }
    self.hasChanges = NO;
    self.navigationItem.prompt = nil;
}

- (void)playRecording
{
    [self saveRecording];
    Socket *socket = [[Socket alloc] init];
    if ([socket connect:@"127.0.0.1" byPort:6000] != 0) {
        [self showError:@"ZXTouch service is unavailable."];
        return;
    }
    [socket send:[@"19" stringByAppendingString:self.scriptBundlePath]];
    NSString *result = [socket recv:1024];
    [socket close];
    if (![result hasPrefix:@"0"]) [self showError:result.length ? result : @"Unable to play this recording."];
}

- (void)showInsertActions:(UIBarButtonItem *)sender
{
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Insert Action" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"Tap" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self promptForTap]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Swipe" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self promptForSwipe]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Wait" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self promptForWait:nil]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Toast" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self promptForToast:nil]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Launch App" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self promptForLaunch:nil]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)promptForTap
{
    [self promptWithTitle:@"Insert Tap" fields:@[@"X coordinate", @"Y coordinate"] defaults:@[@"400", @"400"] completion:^(NSArray<NSString *> *values) {
        CGFloat x = [values[0] doubleValue], y = [values[1] doubleValue];
        [self.actions addObject:[@{ @"kind": @"touch", @"type": @1, @"finger": @1, @"x": @(x), @"y": @(y) } mutableCopy]];
        [self.actions addObject:[@{ @"kind": @"wait", @"microseconds": @50000 } mutableCopy]];
        [self.actions addObject:[@{ @"kind": @"touch", @"type": @0, @"finger": @1, @"x": @(x), @"y": @(y) } mutableCopy]];
        [self markChanged]; [self.tableView reloadData];
    }];
}

- (void)promptForSwipe
{
    [self promptWithTitle:@"Insert Swipe" fields:@[@"Start X", @"Start Y", @"End X", @"End Y", @"Duration seconds"] defaults:@[@"300", @"400", @"600", @"400", @"0.4"] completion:^(NSArray<NSString *> *values) {
        CGFloat startX = [values[0] doubleValue], startY = [values[1] doubleValue], endX = [values[2] doubleValue], endY = [values[3] doubleValue];
        long long duration = MAX(0, (long long)([values[4] doubleValue] * 1000000.0));
        [self.actions addObject:[@{ @"kind": @"touch", @"type": @1, @"finger": @1, @"x": @(startX), @"y": @(startY) } mutableCopy]];
        [self.actions addObject:[@{ @"kind": @"wait", @"microseconds": @(duration) } mutableCopy]];
        [self.actions addObject:[@{ @"kind": @"touch", @"type": @2, @"finger": @1, @"x": @(endX), @"y": @(endY) } mutableCopy]];
        [self.actions addObject:[@{ @"kind": @"touch", @"type": @0, @"finger": @1, @"x": @(endX), @"y": @(endY) } mutableCopy]];
        [self markChanged]; [self.tableView reloadData];
    }];
}

- (void)promptForWait:(NSMutableDictionary *)action
{
    NSString *value = action ? [NSString stringWithFormat:@"%.3f", [action[@"microseconds"] doubleValue] / 1000000.0] : @"0.5";
    [self promptWithTitle:action ? @"Edit Wait" : @"Insert Wait" fields:@[@"Seconds"] defaults:@[value] completion:^(NSArray<NSString *> *values) {
        NSMutableDictionary *target = action ?: [@{ @"kind": @"wait" } mutableCopy];
        target[@"microseconds"] = @(MAX(0, (long long)([values[0] doubleValue] * 1000000.0)));
        if (!action) [self.actions addObject:target];
        [self markChanged]; [self.tableView reloadData];
    }];
}

- (void)promptForToast:(NSMutableDictionary *)action
{
    NSString *text = action[@"text"] ?: @"Done";
    NSString *duration = action[@"duration"] ?: @"2";
    [self promptWithTitle:action ? @"Edit Toast" : @"Insert Toast" fields:@[@"Message", @"Duration seconds"] defaults:@[text, duration] completion:^(NSArray<NSString *> *values) {
        NSMutableDictionary *target = action ?: [@{ @"kind": @"toast", @"type": @"3", @"position": @"0" } mutableCopy];
        target[@"text"] = values[0]; target[@"duration"] = values[1];
        if (!action) [self.actions addObject:target];
        [self markChanged]; [self.tableView reloadData];
    }];
}

- (void)promptForLaunch:(NSMutableDictionary *)action
{
    [self promptWithTitle:action ? @"Edit Launch" : @"Launch App" fields:@[@"Bundle identifier"] defaults:@[action[@"bundle"] ?: @"com.apple.Preferences"] completion:^(NSArray<NSString *> *values) {
        NSMutableDictionary *target = action ?: [@{ @"kind": @"launch" } mutableCopy];
        target[@"bundle"] = values[0];
        if (!action) [self.actions addObject:target];
        [self markChanged]; [self.tableView reloadData];
    }];
}

- (void)promptWithTitle:(NSString *)title fields:(NSArray<NSString *> *)fields defaults:(NSArray<NSString *> *)defaults completion:(void (^)(NSArray<NSString *> *values))completion
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    for (NSUInteger index = 0; index < fields.count; index++) {
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            NSString *label = fields[index];
            BOOL numeric = [label containsString:@"coordinate"] || [label containsString:@"seconds"] || [label containsString:@"Start"] || [label containsString:@"End"];
            field.placeholder = label;
            field.text = defaults[index];
            field.keyboardType = numeric ? UIKeyboardTypeDecimalPad : UIKeyboardTypeDefault;
        }];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *choice) {
        NSMutableArray *values = [NSMutableArray array];
        for (UITextField *field in alert.textFields) [values addObject:field.text ?: @""];
        completion(values);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showError:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Recording Editor" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.actions.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return self.actions.count ? @"Timeline" : @"No actions yet"; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ActionCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ActionCell"];
    NSDictionary *action = self.actions[indexPath.row];
    cell.textLabel.text = [self titleForAction:action];
    cell.detailTextLabel.text = [self detailForAction:action];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSMutableDictionary *action = self.actions[indexPath.row];
    NSString *kind = action[@"kind"];
    if ([kind isEqualToString:@"wait"]) [self promptForWait:action];
    else if ([kind isEqualToString:@"toast"]) [self promptForToast:action];
    else if ([kind isEqualToString:@"launch"]) [self promptForLaunch:action];
    else if ([kind isEqualToString:@"touch"]) {
        [self promptWithTitle:@"Edit Touch" fields:@[@"X coordinate", @"Y coordinate"] defaults:@[[NSString stringWithFormat:@"%.0f", [action[@"x"] doubleValue]], [NSString stringWithFormat:@"%.0f", [action[@"y"] doubleValue]]] completion:^(NSArray<NSString *> *values) {
            action[@"x"] = @([values[0] doubleValue]); action[@"y"] = @([values[1] doubleValue]);
            [self markChanged]; [self.tableView reloadData];
        }];
    } else {
        [self promptWithTitle:@"Edit Command" fields:@[@"Raw command"] defaults:@[action[@"command"] ?: @""] completion:^(NSArray<NSString *> *values) {
            action[@"command"] = values[0]; [self markChanged]; [self.tableView reloadData];
        }];
    }
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath { NSMutableDictionary *action = self.actions[sourceIndexPath.row]; [self.actions removeObjectAtIndex:sourceIndexPath.row]; [self.actions insertObject:action atIndex:destinationIndexPath.row]; [self markChanged]; }
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath { if (editingStyle == UITableViewCellEditingStyleDelete) { [self.actions removeObjectAtIndex:indexPath.row]; [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic]; [self markChanged]; } }

- (NSArray<UIContextualAction *> *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0))
{
    UIContextualAction *duplicate = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Duplicate" handler:^(__unused UIContextualAction *context, __unused UIView *view, void (^completion)(BOOL)) {
        [self.actions insertObject:[self.actions[indexPath.row] mutableCopy] atIndex:indexPath.row + 1];
        [self.tableView reloadData]; [self markChanged]; completion(YES);
    }];
    duplicate.backgroundColor = UIColor.systemBlueColor;
    return @[duplicate];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated
{
    [super setEditing:editing animated:animated];
    [self.tableView setEditing:editing animated:animated];
}

@end
