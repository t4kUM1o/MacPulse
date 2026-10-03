#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
@interface Usage : NSObject <NSApplicationDelegate,NSMenuDelegate>
@property NSStatusItem *item;
@end
@implementation Usage
- (void)applicationDidFinishLaunching:(NSNotification *)n {
 self.item=[NSStatusBar.systemStatusBar statusItemWithLength:110];
 NSImage *logo=[[NSImage alloc] initWithContentsOfFile:@"/Applications/ChatGPT.app/Contents/Resources/chatgptTemplate.png"];
 if(!logo) logo=[NSImage imageWithSystemSymbolName:@"bubble.left.and.bubble.right" accessibilityDescription:@"ChatGPT利用量"];
 logo.size=NSMakeSize(18,18); logo.template=YES; self.item.button.image=logo; self.item.button.imagePosition=NSImageLeft;
 NSMenu *menu=[NSMenu new]; menu.autoenablesItems=NO; menu.delegate=self; self.item.menu=menu; [self rebuild];
 if(![NSUserDefaults.standardUserDefaults boolForKey:@"UsageLoginSetupAttempted"]) {
  [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"UsageLoginSetupAttempted"];
  NSError *e=nil; [SMAppService.mainAppService registerAndReturnError:&e]; if(e) NSLog(@"Login registration: %@",e.localizedDescription);
 }
}
- (void)add:(NSString *)title action:(SEL)action { NSMenuItem *i=[[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""]; i.target=self; i.enabled=action!=NULL; [self.item.menu addItem:i]; }
- (void)menuWillOpen:(NSMenu *)menu { [self rebuild]; }
- (void)rebuild {
 [self.item.menu removeAllItems]; NSNumber *remaining=[NSUserDefaults.standardUserDefaults objectForKey:@"ManualRemainingPercent"];
 self.item.button.title=remaining?[NSString stringWithFormat:@" 残り%@%%",remaining]:@" —";
 self.item.button.toolTip=@"手動入力の利用量 · 自動更新なし";
 [self add:@"ChatGPT 利用量（手動入力）" action:NULL];
 [self add:remaining?[NSString stringWithFormat:@"残り%@%%",remaining]:@"残り使用量: 未入力" action:NULL];
 NSString *date=[NSUserDefaults.standardUserDefaults stringForKey:@"ManualRemainingDate"]; if(date) [self add:[@"入力日時: " stringByAppendingString:date] action:NULL];
 [self add:@"自動取得・自動更新は未対応" action:NULL];
 [self add:@"残り使用量を入力…" action:@selector(editRemaining)];
 [self add:@"ChatGPTで最新の利用量を確認" action:@selector(openUsage)];
 [self.item.menu addItem:NSMenuItem.separatorItem]; SMAppServiceStatus s=SMAppService.mainAppService.status;
 [self add:s==SMAppServiceStatusEnabled?@"✓ ログイン時に自動起動":@"ログイン時に自動起動を有効にする" action:@selector(toggleLogin)];
 if(s==SMAppServiceStatusRequiresApproval) [self add:@"システム設定での許可が必要" action:@selector(settings)];
 [self add:@"ログイン項目の設定を開く" action:@selector(settings)]; [self add:@"終了" action:@selector(quit)];
}
- (void)editRemaining {
 NSAlert *a=[NSAlert new]; a.messageText=@"残りの使用量（%）"; a.informativeText=@"ChatGPTで確認した0〜100の数値を入力してください。自動更新はされません。";
 NSTextField *input=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,260,26)]; NSNumber *old=[NSUserDefaults.standardUserDefaults objectForKey:@"ManualRemainingPercent"]; input.stringValue=old?old.stringValue:@""; a.accessoryView=input; [a addButtonWithTitle:@"保存"]; [a addButtonWithTitle:@"キャンセル"]; [NSApp activateIgnoringOtherApps:YES];
 if([a runModal]!=NSAlertFirstButtonReturn) return;
 NSString *text=[input.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; NSScanner *scanner=[NSScanner scannerWithString:text]; NSInteger value;
 if(![scanner scanInteger:&value] || !scanner.isAtEnd || value<0 || value>100) { NSBeep(); return; }
 [NSUserDefaults.standardUserDefaults setInteger:value forKey:@"ManualRemainingPercent"];
 NSDateFormatter *f=[NSDateFormatter new]; f.dateFormat=@"yyyy/MM/dd HH:mm"; [NSUserDefaults.standardUserDefaults setObject:[f stringFromDate:NSDate.date] forKey:@"ManualRemainingDate"]; [self rebuild];
}
- (void)openUsage { [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://chatgpt.com/#settings/Usage"]]; }
- (void)settings { [SMAppService openSystemSettingsLoginItems]; }
- (void)toggleLogin {
 NSError *e=nil; if(SMAppService.mainAppService.status==SMAppServiceStatusEnabled) [SMAppService.mainAppService unregisterAndReturnError:&e]; else [SMAppService.mainAppService registerAndReturnError:&e];
 if(e) { NSAlert *a=[NSAlert new]; a.messageText=@"自動起動を設定できませんでした"; a.informativeText=e.localizedDescription; [a runModal]; } [self rebuild];
}
- (void)quit { [NSApp terminate:nil]; }
@end
int main(void) { @autoreleasepool { NSApplication *app=NSApplication.sharedApplication; [app setActivationPolicy:NSApplicationActivationPolicyAccessory]; Usage *u=[Usage new]; app.delegate=u; [app run]; } return 0; }
