- (BOOL)option:(NSString *)key { return [NSUserDefaults.standardUserDefaults boolForKey:key]; }
- (NSNumber *)maxGPU {
 NSNumber *max=nil; for(NSDictionary *g in self.gpu) { NSNumber *n=g[@"stats"][@"Device Utilization %"]?:g[@"stats"][@"GPU Activity(%)"]; if([n isKindOfClass:NSNumber.class] && (!max||n.doubleValue>max.doubleValue)) max=n; } return max;
}
- (void)configureTimer {
 [self.refreshTimer invalidate]; double interval=[NSUserDefaults.standardUserDefaults doubleForKey:@"RefreshSeconds"];
 if(interval!=1 && interval!=2 && interval!=5) interval=1;
 self.refreshTimer=[NSTimer timerWithTimeInterval:interval target:self selector:@selector(refresh) userInfo:nil repeats:YES]; [NSRunLoop.mainRunLoop addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
}
- (void)openSettings {
 if(!self.settingsWindow) {
  self.settingsWindow=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,750,650) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO]; self.settingsWindow.title=@"MacPulse · 設定とCPU詳細"; self.settingsWindow.releasedWhenClosed=NO;
  self.settingsWindow.contentView=[[SettingsBackgroundView alloc] initWithFrame:NSMakeRect(0,0,750,650)]; [self.settingsWindow center];
  NSArray *options=@[@[@"メニューバーにCPUを表示",@"ShowCPU"],@[@"メニューバーにGPUを表示",@"ShowGPU"],@[@"メニューバーにファンRPMを表示",@"ShowFanBar"],@[@"CPUのコア別使用率を表示",@"ShowCores"],@[@"メニューに温度を表示",@"ShowTemperature"],@[@"メニューにファン詳細を表示",@"ShowFans"],@[@"メニューにVRAM使用量を表示",@"ShowVRAM"],@[@"CPU・GPUの履歴を記録",@"RecordHistory"]];
  [self settingsLabel:@"表示・便利機能" frame:NSMakeRect(24,606,320,26)];
  self.optionButtons=[NSMutableArray array];
  for(NSUInteger i=0;i<options.count;i++) { NSButton *b=[NSButton checkboxWithTitle:options[i][0] target:self action:@selector(optionChanged:)]; b.frame=NSMakeRect(24,570-i*33,330,26); b.identifier=options[i][1]; b.state=[self option:options[i][1]]?NSControlStateValueOn:NSControlStateValueOff; [self.settingsWindow.contentView addSubview:b]; [self.optionButtons addObject:b]; }
  [self settingsLabel:@"情報の更新間隔" frame:NSMakeRect(24,289,160,24)];
  self.intervalChoice=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(190,285,140,28) pullsDown:NO]; [self.intervalChoice addItemsWithTitles:@[@"1秒",@"2秒",@"5秒"]]; NSArray *intervals=@[@1,@2,@5]; for(int i=0;i<3;i++) self.intervalChoice.itemArray[i].representedObject=intervals[i]; [self.intervalChoice selectItemAtIndex:[intervals indexOfObject:@([NSUserDefaults.standardUserDefaults doubleForKey:@"RefreshSeconds"])]]; self.intervalChoice.target=self; self.intervalChoice.action=@selector(intervalChanged:); [self.settingsWindow.contentView addSubview:self.intervalChoice];
  [self settingsLabel:@"変更はすぐ反映・自動保存されます。表示をオフにしても、ファン制御に必要な温度は読み取り続けます。" frame:NSMakeRect(24,218,305,58)];
  NSButton *copy=[NSButton buttonWithTitle:@"現在の情報をコピー" target:self action:@selector(copySnapshot)]; copy.frame=NSMakeRect(24,171,180,32); [self.settingsWindow.contentView addSubview:copy];
  NSButton *activity=[NSButton buttonWithTitle:@"アクティビティモニタ" target:self action:@selector(openActivity)]; activity.frame=NSMakeRect(24,132,190,32); [self.settingsWindow.contentView addSubview:activity];
  NSButton *curve=[NSButton buttonWithTitle:@"ファンカーブを編集" target:self action:@selector(openCurve)]; curve.frame=NSMakeRect(24,93,180,32); [self.settingsWindow.contentView addSubview:curve];
  self.settingsFanReadout=[self settingsLabel:@"現在のファン回転数: 測定中…" frame:NSMakeRect(24,22,310,62)];
  self.settingsFanReadout.font=[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
  [self settingsLabel:@"CPUの論理コアごとの使用率" frame:NSMakeRect(365,606,360,26)];
  NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(365,326,360,275)]; scroll.hasVerticalScroller=YES; self.coreContainer=[[NSView alloc] initWithFrame:NSMakeRect(0,0,340,275)]; scroll.documentView=self.coreContainer; [self.settingsWindow.contentView addSubview:scroll];
  [self settingsLabel:@"論理コアを表示しています。周波数・電圧の変更やCPUのオーバークロックは行いません。" frame:NSMakeRect(365,276,360,44)];
  self.historyView=[[HistoryView alloc] initWithFrame:NSMakeRect(355,45,380,222)]; [self.settingsWindow.contentView addSubview:self.historyView];
 }
 [self updateSettings]; [self updateFanReadouts]; [NSApp activateIgnoringOtherApps:YES]; [self.settingsWindow makeKeyAndOrderFront:nil];
}
- (NSTextField *)settingsLabel:(NSString *)text frame:(NSRect)frame { NSTextField *l=[NSTextField wrappingLabelWithString:text]; l.frame=frame; [self.settingsWindow.contentView addSubview:l]; return l; }
- (void)optionChanged:(NSButton *)sender {
 [NSUserDefaults.standardUserDefaults setBool:sender.state==NSControlStateValueOn forKey:sender.identifier];
 if([sender.identifier isEqualToString:@"RecordHistory"] && sender.state==NSControlStateValueOff) [self.history removeAllObjects];
 if([sender.identifier isEqualToString:@"ShowCores"]) self.coreTicks=nil;
 [self sampleCPU]; [self updateTitle]; [self rebuildMenu]; [self updateSettings];
}
- (void)intervalChanged:(NSPopUpButton *)sender { [NSUserDefaults.standardUserDefaults setDouble:[sender.selectedItem.representedObject doubleValue] forKey:@"RefreshSeconds"]; [self configureTimer]; [self rebuildMenu]; }
- (void)updateSettings {
 if(!self.settingsWindow) return;
 for(NSView *v in self.coreContainer.subviews.copy) [v removeFromSuperview];
 BOOL show=[self option:@"ShowCores"]; NSUInteger count=show?self.coreUsage.count:0; CGFloat height=MAX(275,count*32+15); self.coreContainer.frame=NSMakeRect(0,0,340,height);
 if(!count) { NSTextField *l=[NSTextField labelWithString:show?@"コア情報を測定中…":@"コア別表示はオフです"]; l.frame=NSMakeRect(10,height-35,320,25); [self.coreContainer addSubview:l]; }
 for(NSUInteger i=0;i<count;i++) {
  CGFloat y=height-35-i*32; id value=self.coreUsage[i]; BOOL valid=[value isKindOfClass:NSNumber.class];
  NSTextField *l=[NSTextField labelWithString:[NSString stringWithFormat:@"コア%2lu  %@",(unsigned long)i+1,valid?[self percent:value]:@"  —%"]]; l.font=[NSFont fontWithName:@"Menlo" size:11]; l.frame=NSMakeRect(8,y,120,23); [self.coreContainer addSubview:l];
  NSLevelIndicator *bar=[[NSLevelIndicator alloc] initWithFrame:NSMakeRect(135,y+4,190,14)]; bar.levelIndicatorStyle=NSLevelIndicatorStyleContinuousCapacity; bar.minValue=0; bar.maxValue=100; bar.warningValue=70; bar.criticalValue=90; bar.doubleValue=valid?[value doubleValue]:0; [self.coreContainer addSubview:bar];
 }
 self.historyView.samples=self.history.copy; self.historyView.needsDisplay=YES;
}
- (void)copySnapshot {
 NSDictionary *d=@{@"timestamp":self.updated.description?:@"",@"cpu":self.cpu?:NSNull.null,@"logicalCoreUsage":self.coreUsage?:@[],@"fans":self.fans?:@{},@"gpu":self.gpu?:@[]}; NSData *data=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil];
 if(data) { [NSPasteboard.generalPasteboard clearContents]; [NSPasteboard.generalPasteboard setString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] forType:NSPasteboardTypeString]; }
}
- (void)openActivity { [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:@"/System/Applications/Utilities/Activity Monitor.app"]]; }
