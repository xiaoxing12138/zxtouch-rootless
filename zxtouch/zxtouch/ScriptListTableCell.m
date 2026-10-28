//
//  ScriptListTableCell.m
//  zxtouch
//
//  Created by Jason on 2020/12/14.
//

#import "ScriptListTableCell.h"
#import "ZXScriptListView.h"
#import "Socket.h"
#import "Util.h"

@implementation ScriptListTableCell
{
    NSString *filePath;
    ZXScriptListView *scriptRow;
}

- (void)awakeFromNib {
    [super awakeFromNib];
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.scriptTitle.hidden = YES;
    if (self.iconImage) self.iconImage.hidden = YES;

    UIImage *playImage = [UIImage systemImageNamed:@"play.circle.fill"];
    [_playButton setBackgroundImage:nil forState:UIControlStateNormal];
    [_playButton setImage:playImage forState:UIControlStateNormal];
    _playButton.tintColor = [UIColor systemGreenColor];
    _playButton.backgroundColor = [UIColor clearColor];

    for (UIView *view in self.contentView.subviews) {
        if ([view isKindOfClass:[UIButton class]] && view != _playButton) {
            UIButton *button = (UIButton *)view;
            [button setTitle:@"" forState:UIControlStateNormal];
            [button setBackgroundImage:nil forState:UIControlStateNormal];
            [button setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
            button.tintColor = [UIColor secondaryLabelColor];
            button.backgroundColor = [UIColor clearColor];
        }
    }

    [self setupScriptRowIfNeeded];
}

- (void)setupScriptRowIfNeeded {
    if (scriptRow) return;

    scriptRow = [[ZXScriptListView alloc] initWithFrame:CGRectZero];
    scriptRow.translatesAutoresizingMaskIntoConstraints = NO;
    scriptRow.showsDisclosure = NO;
    scriptRow.swipeDeleteEnabled = NO;
    [self.contentView addSubview:scriptRow];

    __weak typeof(self) weakSelf = self;
    scriptRow.onLongPress = ^(ZXScriptListItem *item) {
        if (weakSelf.onLongPress) weakSelf.onLongPress();
    };
    scriptRow.onTap = ^(ZXScriptListItem *item) {
        if (weakSelf.onRowTap) weakSelf.onRowTap();
    };

    UIButton *moreButton = nil;
    for (UIView *view in self.contentView.subviews) {
        if ([view isKindOfClass:[UIButton class]] && view != _playButton) {
            moreButton = (UIButton *)view;
            break;
        }
    }

    NSMutableArray<NSLayoutConstraint *> *rules = [NSMutableArray array];
    [rules addObject:[scriptRow.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16]];
    [rules addObject:[scriptRow.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16]];
    [rules addObject:[scriptRow.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5]];
    [rules addObject:[scriptRow.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5]];

    if (moreButton) {
        [moreButton removeFromSuperview];
        moreButton.translatesAutoresizingMaskIntoConstraints = NO;
        [scriptRow addSubview:moreButton];
        [rules addObject:[moreButton.trailingAnchor constraintEqualToAnchor:scriptRow.trailingAnchor constant:-8]];
        [rules addObject:[moreButton.centerYAnchor constraintEqualToAnchor:scriptRow.centerYAnchor]];
        [rules addObject:[moreButton.widthAnchor constraintEqualToConstant:30]];
        [rules addObject:[moreButton.heightAnchor constraintEqualToConstant:30]];
    }

    if (_playButton) {
        UIButton *play = _playButton;   // outlet 是 weak，先拿到强引用再摘下来
        [play removeFromSuperview];
        play.translatesAutoresizingMaskIntoConstraints = NO;
        [scriptRow addSubview:play];
        UIView *right = moreButton ?: scriptRow;
        [rules addObject:[play.trailingAnchor constraintEqualToAnchor:right.trailingAnchor constant:(moreButton ? -42.0f : -8.0f)]];
        [rules addObject:[play.centerYAnchor constraintEqualToAnchor:scriptRow.centerYAnchor]];
        [rules addObject:[play.widthAnchor constraintEqualToConstant:28]];
        [rules addObject:[play.heightAnchor constraintEqualToConstant:28]];
    }

    [NSLayoutConstraint activateConstraints:rules];
}

- (IBAction)playButtonClick:(id)sender {
    Socket *springBoardSocket = [[Socket alloc] init];
    if ([springBoardSocket connect:@"127.0.0.1" byPort:6000] != 0)
    {
        [Util showAlertBoxWithOneOption:_parentViewController title:@"错误" message:@"小新Lap 服务不可用。" buttonString:@"确定"];
        [springBoardSocket close];
        return;
    }

    [springBoardSocket send:[NSString stringWithFormat:@"19%@\r\n", filePath]];
    NSString* result = [springBoardSocket recv:1024];
    if (result.length == 0 || [result characterAtIndex:0] != '0')
    {
        [Util showAlertBoxWithOneOption:_parentViewController title:@"错误" message:[NSString stringWithFormat:@"无法运行脚本。错误：%@", result.length ? result : @"服务无响应"] buttonString:@"确定"];
    }
    [springBoardSocket close];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    filePath = nil;
    self.onLongPress = nil;
    self.onRowTap = nil;
    _playButton.hidden = NO;
}

- (void)setPropertyWithPath:(NSString *)path {
    filePath = path;
    [self setupScriptRowIfNeeded];

    ZXScriptListItem *item = [ZXScriptListItem itemWithPath:path];
    scriptRow.trailingInset = item.isScript ? 78.0f : 44.0f;
    [scriptRow applyItem:item];
    _playButton.hidden = !item.isScript;
}

@end
