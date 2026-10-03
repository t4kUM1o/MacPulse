#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <math.h>
#include <string.h>
// AppleSMC's read protocol: key metadata (9), then bytes (5), selector 2.
// Protocol reference: github.com/hholtmann/smcFanControl/tree/master/smc-command
// Curve control raises the minimum speed; SMC automatic control stays enabled.
typedef struct {
 uint32_t key;
 struct { uint8_t major,minor,build,reserved; uint16_t release; } version;
 struct { uint16_t version,length; uint32_t cpu,gpu,memory; } limits;
 struct { uint32_t size,type; uint8_t attributes; } info;
 uint8_t result,status,command;
 uint32_t index;
 uint8_t bytes[32];
} SMCPacket;
_Static_assert(sizeof(SMCPacket)==80,"SMC packet ABI");
static uint32_t fourCC(const char *s) { return (uint32_t)(uint8_t)s[0]<<24 | (uint32_t)(uint8_t)s[1]<<16 | (uint32_t)(uint8_t)s[2]<<8 | (uint8_t)s[3]; }
static BOOL smcRead(io_connect_t c,const char *key,SMCPacket *value) {
 SMCPacket in={0},out={0}; size_t size=sizeof(out);
 in.key=fourCC(key); in.command=9;
 if(IOConnectCallStructMethod(c,2,&in,sizeof(in),&out,&size)!=KERN_SUCCESS || out.result || out.info.size==0 || out.info.size>32) return NO;
 in.info=out.info; in.command=5; memset(&out,0,sizeof(out)); size=sizeof(out);
 if(IOConnectCallStructMethod(c,2,&in,sizeof(in),&out,&size)!=KERN_SUCCESS || out.result) return NO;
 out.info=in.info; *value=out; return YES;
}
static NSNumber *decode(SMCPacket p) {
 double n;
 if(p.info.type==fourCC("fpe2") && p.info.size==2) n=((p.bytes[0]<<8)|p.bytes[1])/4.0;
 else if(p.info.type==fourCC("sp78") && p.info.size==2) n=(int16_t)((p.bytes[0]<<8)|p.bytes[1])/256.0;
 else if(p.info.type==fourCC("flt ") && p.info.size==4) { float f; memcpy(&f,p.bytes,4); n=f; }
 else if(p.info.type==fourCC("ui8 ") && p.info.size==1) n=p.bytes[0];
 else if(p.info.type==fourCC("ui16") && p.info.size==2) n=(p.bytes[0]<<8)|p.bytes[1];
 else return nil;
 return isfinite(n) ? @(n) : nil;
}
static NSNumber *readNumber(io_connect_t c,const char *key) { SMCPacket p; return smcRead(c,key,&p)?decode(p):nil; }
static NSDictionary *fanSnapshot(void) {
 io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
 if(!service) return @{ @"error":@"AppleSMCが見つかりません" };
 io_connect_t c=0; kern_return_t r=IOServiceOpen(service,mach_task_self(),0,&c); IOObjectRelease(service);
 if(r!=KERN_SUCCESS) return @{ @"error":[NSString stringWithFormat:@"SMC接続失敗 (0x%08x) · 権限または機種の制限",r] };
 NSNumber *count=readNumber(c,"FNum"); NSMutableArray *fans=[NSMutableArray array];
 if(count && count.intValue>=0 && count.intValue<=16) {
  for(int i=0;i<count.intValue;i++) {
   NSMutableDictionary *fan=[NSMutableDictionary dictionaryWithObject:@(i+1) forKey:@"number"];
   const char *suffixes[]={"Ac","Mn","Mx","Tg"}; NSArray *labels=@[@"current",@"minimum",@"maximum",@"target"];
   for(int j=0;j<4;j++) { char key[5]; snprintf(key,sizeof(key),"F%X%s",i,suffixes[j]); NSNumber *v=readNumber(c,key); if(v && v.doubleValue>=0 && v.doubleValue<=30000) fan[labels[j]]=v; }
   char key[5]; snprintf(key,sizeof(key),"F%XID",i); SMCPacket p;
   if(smcRead(c,key,&p) && p.info.size>4) { size_t len=strnlen((char *)p.bytes+4,p.info.size-4); NSString *name=[[NSString alloc] initWithBytes:p.bytes+4 length:len encoding:NSUTF8StringEncoding]; if(name.length) fan[@"name"]=name; }
   [fans addObject:fan];
  }
 }
 NSMutableDictionary *result=[NSMutableDictionary dictionaryWithObject:fans forKey:@"fans"];
 if(!count) result[@"error"]=@"ファン数キーFNumが取得できません（未対応機種またはSMC応答なし）";
 else if(count.intValue>16 || count.intValue<0) result[@"error"]=@"ファン数が想定範囲外です";
 const char *temps[]={"TC0P","TC0D","TC0H"};
 for(int i=0;i<3;i++) { NSNumber *t=readNumber(c,temps[i]); if(t && t.doubleValue>0 && t.doubleValue<130) { result[@"cpuTemperature"]=t; result[@"temperatureKey"]=@(temps[i]); break; } }
 IOServiceClose(c); return result;
}
static NSArray *gpuSnapshot(void) {
 io_iterator_t it=0; NSMutableArray *gpus=[NSMutableArray array];
 if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOAccelerator"),&it)!=KERN_SUCCESS) return gpus;
 io_service_t s;
 while((s=IOIteratorNext(it))) {
  CFMutableDictionaryRef props=NULL;
  if(IORegistryEntryCreateCFProperties(s,&props,kCFAllocatorDefault,0)==KERN_SUCCESS) {
   NSDictionary *d=CFBridgingRelease(props); NSDictionary *stats=d[@"PerformanceStatistics"];
   if([stats isKindOfClass:NSDictionary.class]) { io_name_t name; IORegistryEntryGetName(s,name); [gpus addObject:@{@"name":@(name),@"stats":stats}]; }
  }
  IOObjectRelease(s);
 }
 IOObjectRelease(it); return gpus;
}
static NSString *rpm(NSNumber *n) { return n ? [NSString stringWithFormat:@"%.0f RPM",n.doubleValue] : @"取得不可"; }
#include "curve.inc"
#include "settings-view.inc"
@interface Monitor : NSObject <NSApplicationDelegate,NSMenuDelegate,CurveViewDelegate>
@property NSStatusItem *item;
@property NSArray *gpu;
@property NSDictionary *fans;
@property NSNumber *cpu;
@property BOOL compact,busy;
@property uint64_t previousTotal,previousIdle;
@property NSDate *updated;
@property NSWindow *curveWindow;
@property CurveView *curveView;
@property NSPopUpButton *fanChoice,*sensorChoice;
@property NSTextField *curveLabel;
@property NSTextField *curveFanReadout,*settingsFanReadout;
@property NSButton *applyButton;
@property NSTask *curveTask;
@property NSPipe *curvePipe;
@property NSString *curveConfig;
@property BOOL curveRequested;
@property NSString *curveError;
@property NSTimer *refreshTimer;
@property NSMenu *pendingMenu;
@property NSString *menuSection;
@property BOOL menuOpen;
@property NSArray *coreTicks,*coreUsage;
@property NSMutableArray *history,*optionButtons;
@property NSWindow *settingsWindow;
@property NSView *coreContainer;
@property HistoryView *historyView;
@property NSPopUpButton *intervalChoice;
- (void)openCurve;
- (void)stopCurve;

@end
@implementation Monitor
- (void)applicationDidFinishLaunching:(NSNotification *)n {
 [NSUserDefaults.standardUserDefaults registerDefaults:@{@"ShowCPU":@YES,@"ShowGPU":@(![NSUserDefaults.standardUserDefaults boolForKey:@"MacPulseCompact"]),@"ShowFanBar":@NO,@"ShowCores":@YES,@"ShowTemperature":@YES,@"ShowFans":@YES,@"ShowVRAM":@YES,@"RecordHistory":@YES,@"RefreshSeconds":@1}];
 self.history=[NSMutableArray array];
 self.compact=[NSUserDefaults.standardUserDefaults boolForKey:@"MacPulseCompact"];
 self.item=[NSStatusBar.systemStatusBar statusItemWithLength:self.compact?82:156];
 self.item.button.font=[NSFont fontWithName:@"Menlo" size:12];
 NSMenu *menu=[NSMenu new]; menu.autoenablesItems=NO; menu.delegate=self; self.item.menu=menu;
 [self sampleCPU]; [self refresh]; [self updateTitle]; [self rebuildMenu];
 [self configureTimer];
 if(![NSUserDefaults.standardUserDefaults boolForKey:@"MacPulseLoginSetupAttempted"]) {
  [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"MacPulseLoginSetupAttempted"];
  NSError *error=nil; [SMAppService.mainAppService registerAndReturnError:&error];
  if(error) NSLog(@"Login registration: %@",error.localizedDescription);
 }
}
- (void)sampleCPU {
 if([self option:@"ShowCores"]) { NSArray *next=nil; self.coreUsage=coreLoads(self.coreTicks,&next); self.coreTicks=next; } else self.coreUsage=@[];
 host_cpu_load_info_data_t info; mach_msg_type_number_t count=HOST_CPU_LOAD_INFO_COUNT;
 mach_port_t host=mach_host_self(); kern_return_t r=host_statistics(host,HOST_CPU_LOAD_INFO,(host_info_t)&info,&count); mach_port_deallocate(mach_task_self(),host);
 if(r!=KERN_SUCCESS) { self.cpu=nil; return; }
 uint64_t total=0; for(int i=0;i<CPU_STATE_MAX;i++) total+=info.cpu_ticks[i]; uint64_t idle=info.cpu_ticks[CPU_STATE_IDLE];
 if(self.previousTotal && total>self.previousTotal && idle>=self.previousIdle) self.cpu=@(fmax(0,fmin(100,100.0*(1.0-(double)(idle-self.previousIdle)/(total-self.previousTotal)))));
 self.previousTotal=total; self.previousIdle=idle;
}
- (void)refresh {
 [self updateCurveControl];
 if(self.busy) return; self.busy=YES; [self sampleCPU];
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
  NSArray *gpu=gpuSnapshot(); NSDictionary *fans=fanSnapshot();
  CFRunLoopPerformBlock(CFRunLoopGetMain(),kCFRunLoopCommonModes,^{
   self.gpu=gpu; self.fans=fans; self.updated=NSDate.date; self.busy=NO;
   if([self option:@"RecordHistory"]) { [self.history addObject:@{@"cpu":self.cpu?:NSNull.null,@"gpu":[self maxGPU]?:NSNull.null}]; if(self.history.count>120) [self.history removeObjectAtIndex:0]; }
   [self updateTitle]; [self rebuildMenu]; [self updateSettings]; [self updateFanReadouts];
   if([NSProcessInfo.processInfo.arguments containsObject:@"--show-settings"] && !self.settingsWindow) [self openSettings];
   if([NSProcessInfo.processInfo.arguments containsObject:@"--show-curve"] && !self.curveWindow) [self openCurve];
  });
  CFRunLoopWakeUp(CFRunLoopGetMain());
 });
}
- (NSString *)percent:(NSNumber *)n { return n ? [NSString stringWithFormat:@"%3.0f%%",n.doubleValue] : @"  —%"; }
- (void)updateTitle {
 NSMutableArray *parts=[NSMutableArray array];
 if([self option:@"ShowCPU"]) [parts addObject:[@"CPU " stringByAppendingString:[self percent:self.cpu]]];
 if([self option:@"ShowGPU"]) [parts addObject:[@"GPU " stringByAppendingString:[self percent:[self maxGPU]]]];
 if([self option:@"ShowFanBar"]) { NSNumber *speed=[self.fans[@"fans"] firstObject][@"current"]; [parts addObject:speed?[NSString stringWithFormat:@"FAN %5.0f",speed.doubleValue]:@"FAN     —"]; }
 NSString *text=parts.count?[parts componentsJoinedByString:@"  "]:@"◉";
 self.item.length=parts.count?text.length*7.3+24:28;
 self.item.button.title=text;
}
- (void)add:(NSString *)s action:(SEL)action {
 if([s hasPrefix:@"GPU "] || [s hasPrefix:@"ファン "]) self.menuSection=s;
 NSRegularExpression *numbers=[NSRegularExpression regularExpressionWithPattern:@"[0-9]+(?:\\.[0-9]+)?" options:0 error:nil];
 NSString *key=[numbers stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0,s.length) withTemplate:@"#"];
 NSRegularExpression *spaces=[NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
 key=[spaces stringByReplacingMatchesInString:key options:0 range:NSMakeRange(0,key.length) withTemplate:@" "];
 NSMenuItem *i=[[NSMenuItem alloc] initWithTitle:s action:action keyEquivalent:@""]; i.target=self; i.enabled=action!=NULL;
 i.representedObject=action?NSStringFromSelector(action):[NSString stringWithFormat:@"%@/%@",self.menuSection?:@"main",key];
 [self.pendingMenu addItem:i];
}
- (void)separator { [self.pendingMenu addItem:NSMenuItem.separatorItem]; }
- (void)menuWillOpen:(NSMenu *)menu { [self rebuildMenu]; self.menuOpen=YES; }
- (void)menuDidClose:(NSMenu *)menu { self.menuOpen=NO; [self rebuildMenu]; }
- (void)rebuildMenu {
 self.pendingMenu=[NSMenu new]; self.pendingMenu.autoenablesItems=NO; self.menuSection=@"main";
 [self add:@"MacPulse · システムモニター" action:NULL];
 NSDateFormatter *f=[NSDateFormatter new]; f.dateFormat=@"HH:mm:ss";
 [self add:self.updated?[NSString stringWithFormat:@"更新 %@ · 約%.0f秒間隔",[f stringFromDate:self.updated],[NSUserDefaults.standardUserDefaults doubleForKey:@"RefreshSeconds"]]:@"測定中…" action:NULL];
 [self add:[NSString stringWithFormat:@"CPU 使用率: %@",[self percent:self.cpu]] action:NULL];
 [self add:[NSString stringWithFormat:@"論理コア: %lu · メモリ: %.0f GB",(unsigned long)NSProcessInfo.processInfo.processorCount,NSProcessInfo.processInfo.physicalMemory/1073741824.0] action:NULL];
 NSNumber *t=self.fans[@"cpuTemperature"]; if(t && [self option:@"ShowTemperature"]) [self add:[NSString stringWithFormat:@"CPU温度: %.1f °C (%@)",t.doubleValue,self.fans[@"temperatureKey"]] action:NULL];
 if([self option:@"ShowFans"]) {
 [self separator]; [self add:@"Mac本体のファン（SMC）" action:NULL];
 if(self.fans[@"error"]) [self add:self.fans[@"error"] action:NULL];
 NSArray *fans=self.fans[@"fans"];
 if(!self.fans) [self add:@"測定中…" action:NULL];
 else if(fans.count==0 && !self.fans[@"error"]) [self add:@"SMCが報告したファン数: 0" action:NULL];
 for(NSDictionary *fan in fans) {
  [self add:[NSString stringWithFormat:@"ファン %@%@",fan[@"number"],fan[@"name"]?[NSString stringWithFormat:@" · %@",fan[@"name"]]:@""] action:NULL];
  [self add:[NSString stringWithFormat:@"  現在 %@ · 目標 %@",rpm(fan[@"current"]),rpm(fan[@"target"])] action:NULL];
  [self add:[NSString stringWithFormat:@"  最低 %@ · 最高 %@",rpm(fan[@"minimum"]),rpm(fan[@"maximum"])] action:NULL];
 }
 }
 [self add:self.curveRequested?@"回転数の制御: 温度カーブ（最低回転数）":@"回転数の制御: macOSの自動制御" action:NULL];
 [self add:@"温度カーブを編集…" action:@selector(openCurve)];
 if(self.curveRequested) [self add:@"カーブを停止して自動制御に戻す" action:@selector(stopCurve)];
 [self separator];
 NSUInteger index=0;
 for(NSDictionary *g in self.gpu) {
  NSDictionary *s=g[@"stats"]; [self add:[NSString stringWithFormat:@"GPU %lu · %@",(unsigned long)++index,g[@"name"]] action:NULL];
  [self add:[NSString stringWithFormat:@"  使用率: %@",[self percent:s[@"Device Utilization %"]?:s[@"GPU Activity(%)"]]] action:NULL];
  if(s[@"Temperature(C)"] && [self option:@"ShowTemperature"]) [self add:[NSString stringWithFormat:@"  温度: %@ °C",s[@"Temperature(C)"]] action:NULL];
  if([self option:@"ShowFans"]) {
  NSNumber *speed=s[@"Fan Speed(RPM)"],*percent=s[@"Fan Speed(%)"];
  [self add:[NSString stringWithFormat:@"  GPUファン: %@",rpm(speed)] action:NULL];
  if(speed && speed.doubleValue==0) [self add:@"  0 RPM: 停止中またはドライバー未報告" action:NULL];
  if(percent) [self add:[NSString stringWithFormat:@"  GPUファン出力: %@%%",percent] action:NULL];
  }
  if(s[@"Core Clock(MHz)"]) [self add:[NSString stringWithFormat:@"  コアクロック: %@ MHz",s[@"Core Clock(MHz)"]] action:NULL];
  if(s[@"inUseVidMemoryBytes"] && [self option:@"ShowVRAM"]) [self add:[NSString stringWithFormat:@"  VRAM使用量: %.0f MB",[s[@"inUseVidMemoryBytes"] doubleValue]/1048576] action:NULL];
 }
 if(!self.gpu.count) [self add:@"GPU詳細: ドライバーから情報を取得できません" action:NULL];
 [self separator];
 SMAppServiceStatus state=SMAppService.mainAppService.status;
 [self add:state==SMAppServiceStatusEnabled?@"✓ ログイン時に自動起動":@"ログイン時に自動起動を有効にする" action:@selector(toggleLogin)];
 if(state==SMAppServiceStatusRequiresApproval) [self add:@"自動起動: システム設定での許可が必要" action:@selector(loginSettings)];
 [self add:@"ログイン項目の設定を開く" action:@selector(loginSettings)];
 [self add:@"設定…" action:@selector(openSettings)];
 [self add:@"ファン診断結果を保存…" action:@selector(saveDiagnostics)];
 [self add:@"終了" action:@selector(quit)];
 if(self.menuOpen) {
  // Keep the tracked items and selection; only change the matching titles.
  NSMutableDictionary *fresh=[NSMutableDictionary dictionary];
  for(NSMenuItem *i in self.pendingMenu.itemArray) if(i.representedObject) fresh[i.representedObject]=i;
  for(NSMenuItem *i in self.item.menu.itemArray) {
   NSMenuItem *replacement=i.representedObject?fresh[i.representedObject]:nil;
   if(replacement) { i.title=replacement.title; i.enabled=replacement.enabled; }
  }
 } else {
  [self.item.menu removeAllItems];
  for(NSMenuItem *i in self.pendingMenu.itemArray.copy) { [self.pendingMenu removeItem:i]; [self.item.menu addItem:i]; }
 }
 self.pendingMenu=nil;
}
- (void)toggleLogin {
 NSError *e=nil;
 if(SMAppService.mainAppService.status==SMAppServiceStatusEnabled) [SMAppService.mainAppService unregisterAndReturnError:&e]; else [SMAppService.mainAppService registerAndReturnError:&e];
 if(e) { NSAlert *alert=[NSAlert new]; alert.messageText=@"自動起動を設定できませんでした"; alert.informativeText=e.localizedDescription; [alert runModal]; } [self rebuildMenu];
}
- (void)loginSettings { [SMAppService openSystemSettingsLoginItems]; }
- (void)toggleCompact { self.compact=!self.compact; [NSUserDefaults.standardUserDefaults setBool:self.compact forKey:@"MacPulseCompact"]; [self updateTitle]; [self rebuildMenu]; }
- (void)saveDiagnostics {
 NSSavePanel *panel=[NSSavePanel savePanel]; panel.nameFieldStringValue=@"MacPulse-fan-diagnostics.json";
 [NSApp activateIgnoringOtherApps:YES];
 if([panel runModal]==NSModalResponseOK) { NSDictionary *d=@{@"timestamp":NSDate.date.description,@"fans":self.fans?:@{},@"gpu":self.gpu?:@[]}; NSError *e=nil; NSData *data=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:&e]; if(data) [data writeToURL:panel.URL options:NSDataWritingAtomic error:&e]; if(e) { NSAlert *a=[NSAlert new]; a.messageText=@"保存に失敗しました"; a.informativeText=e.localizedDescription; [a runModal]; } }
}
- (NSTextField *)label:(NSString *)s frame:(NSRect)r { NSTextField *l=[NSTextField wrappingLabelWithString:s]; l.frame=r; [self.curveWindow.contentView addSubview:l]; return l; }
- (void)openCurve {
 if(!self.curveWindow) {
  self.curveWindow=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,680,560) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO]; self.curveWindow.title=@"MacPulse · 温度とファンのカーブ"; self.curveWindow.releasedWhenClosed=NO;
  self.curveWindow.contentView=[[SettingsBackgroundView alloc] initWithFrame:NSMakeRect(0,0,680,560)]; [self.curveWindow center];
  [self label:@"温度に合わせて、最低回転数を設定" frame:NSMakeRect(24,520,630,25)];
  [self label:@"点をドラッグして編集。%は最大RPMに対する割合です。macOSは必要に応じてさらに回転数を上げられます。" frame:NSMakeRect(24,470,630,42)];
  [self label:@"ファン" frame:NSMakeRect(24,436,48,24)]; self.fanChoice=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(75,432,245,28) pullsDown:NO];
  for(NSDictionary *fan in self.fans[@"fans"]) { [self.fanChoice addItemWithTitle:[NSString stringWithFormat:@"ファン %@ · %@",fan[@"number"],fan[@"name"]?:@""]]; self.fanChoice.lastItem.representedObject=@([fan[@"number"] intValue]-1); } self.fanChoice.target=self; self.fanChoice.action=@selector(fanSelectionChanged:); [self.curveWindow.contentView addSubview:self.fanChoice];
  [self label:@"温度" frame:NSMakeRect(342,436,48,24)]; self.sensorChoice=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(390,432,264,28) pullsDown:NO]; [self.sensorChoice addItemsWithTitles:@[@"CPU",@"GPU",@"CPU / GPU の高い方"]]; [self.curveWindow.contentView addSubview:self.sensorChoice];
  self.curveView=[[CurveView alloc] initWithFrame:NSMakeRect(18,186,644,239)]; self.curveView.curveDelegate=self;
  NSArray *saved=[NSUserDefaults.standardUserDefaults arrayForKey:@"FanCurvePoints"]; if(validCurve(saved)) self.curveView.points=[saved mutableCopy]; [self.curveWindow.contentView addSubview:self.curveView];
  self.curveFanReadout=[self label:@"現在のファン回転数: 測定中…" frame:NSMakeRect(24,158,630,25)];
  self.curveFanReadout.font=[NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightMedium];
  self.curveLabel=[self label:@"適用ボタンを押すまで回転数は変わりません。" frame:NSMakeRect(24,98,630,55)];
  self.applyButton=[NSButton buttonWithTitle:@"カーブを適用" target:self action:@selector(applyCurve)]; self.applyButton.frame=NSMakeRect(24,48,160,32); [self.curveWindow.contentView addSubview:self.applyButton];
  NSButton *stop=[NSButton buttonWithTitle:@"自動制御に戻す" target:self action:@selector(stopCurve)]; stop.frame=NSMakeRect(196,48,170,32); [self.curveWindow.contentView addSubview:stop];
  NSButton *reset=[NSButton buttonWithTitle:@"カーブを初期値に" target:self action:@selector(resetCurve)]; reset.frame=NSMakeRect(480,48,174,32); [self.curveWindow.contentView addSubview:reset];
  [self label:@"元の最低RPM以下には下げません。90℃以上は100%。終了・温度取得失敗・通信途絶で元に戻します。" frame:NSMakeRect(24,8,630,32)];
 }
 [self updateFanReadouts]; [NSApp activateIgnoringOtherApps:YES]; [self.curveWindow makeKeyAndOrderFront:nil];
}
- (void)fanSelectionChanged:(id)sender { [self updateFanReadouts]; }
- (void)updateFanReadouts {
 NSArray *fans=self.fans[@"fans"];
 NSMutableArray *lines=[NSMutableArray array];
 for(NSDictionary *fan in fans) [lines addObject:[NSString stringWithFormat:@"ファン %@: %@",fan[@"number"],rpm(fan[@"current"])]];
 self.settingsFanReadout.stringValue=lines.count?[@"現在の回転数\n" stringByAppendingString:[lines componentsJoinedByString:@" · "]]:@"現在のファン回転数: 取得不可";
 if(self.curveFanReadout) {
  NSDictionary *selected=nil; NSNumber *number=self.fanChoice.selectedItem.representedObject;
  for(NSDictionary *fan in fans) if(number && [fan[@"number"] intValue]==number.intValue+1) { selected=fan; break; }
  self.curveFanReadout.stringValue=selected?[NSString stringWithFormat:@"現在の回転数: %@  ·  目標: %@",rpm(selected[@"current"]),rpm(selected[@"target"])]:@"現在のファン回転数: 取得不可";
 }
}
- (void)curveChanged { [NSUserDefaults.standardUserDefaults setObject:self.curveView.points forKey:@"FanCurvePoints"]; if(self.curveRequested) [self writeCurveConfig]; }
- (void)resetCurve { self.curveView.points=[defaultCurve() mutableCopy]; self.curveView.needsDisplay=YES; [self curveChanged]; }
- (void)writeCurveConfig {
 if(!self.curveConfig) return;
 NSDictionary *d=@{@"enabled":@(self.curveRequested),@"heartbeat":@(NSDate.date.timeIntervalSince1970),@"fan":self.fanChoice.selectedItem.representedObject?:@0,@"sensor":self.sensorChoice.indexOfSelectedItem==0?@"CPU":self.sensorChoice.indexOfSelectedItem==1?@"GPU":@"max",@"points":self.curveView.points?:defaultCurve()};
 NSData *data=[NSJSONSerialization dataWithJSONObject:d options:0 error:nil]; NSError *error=nil;
 if(![data writeToFile:self.curveConfig options:NSDataWritingAtomic error:&error]) { self.curveError=error.localizedDescription; self.curveRequested=NO; }
}
- (void)applyCurve {
 if(self.curveTask.running) return;
 if(!self.fanChoice.numberOfItems) { self.curveLabel.stringValue=@"本体ファンを取得できないため適用できません。"; return; }
 [self curveChanged];
 NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"MacPulse-" stringByAppendingString:NSUUID.UUID.UUIDString]];
 NSError *e=nil; if(![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&e]) { self.curveLabel.stringValue=e.localizedDescription; return; }
 self.curveConfig=[dir stringByAppendingPathComponent:@"curve.json"]; NSString *status=[self.curveConfig stringByAppendingString:@".status"];
 [@"{}" writeToFile:status atomically:YES encoding:NSUTF8StringEncoding error:nil]; chmod(status.fileSystemRepresentation,0600);
 self.curveRequested=YES; self.curveError=nil; [self writeCurveConfig]; if(!self.curveRequested) return;
 // macOS displays its own administrator authentication dialog on Apply.
 NSString *(^quote)(NSString *)=^NSString *(NSString *v) { return [NSString stringWithFormat:@"'%@'",[v stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]]; };
 NSString *command=[NSString stringWithFormat:@"%@ --curve-helper %@ %d %d",quote(NSBundle.mainBundle.executablePath),quote(self.curveConfig),getpid(),getuid()];
 NSString *escaped=[[command stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
 NSString *script=[NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges",escaped];
 self.curveTask=[NSTask new]; self.curveTask.executableURL=[NSURL fileURLWithPath:@"/usr/bin/osascript"]; self.curveTask.arguments=@[@"-e",script]; self.curvePipe=[NSPipe pipe]; self.curveTask.standardError=self.curvePipe; self.curveTask.standardOutput=NSFileHandle.fileHandleWithNullDevice;
 if(![self.curveTask launchAndReturnError:&e]) { self.curveRequested=NO; self.curveError=e.localizedDescription; self.curveLabel.stringValue=self.curveError; return; }
 self.curveLabel.stringValue=@"管理者の認証待ち…"; self.fanChoice.enabled=NO; self.sensorChoice.enabled=NO; self.applyButton.enabled=NO;
}
- (void)stopCurve { self.curveRequested=NO; [self writeCurveConfig]; if(self.curveTask.running) self.curveLabel.stringValue=@"元の最低回転数に戻しています…"; }
- (void)updateCurveControl {
 if(self.curveRequested) [self writeCurveConfig];
 if(!self.curveTask) return;
 NSData *data=[NSData dataWithContentsOfFile:[self.curveConfig stringByAppendingString:@".status"]]; NSDictionary *d=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
 if([d[@"active"] boolValue]) self.curveLabel.stringValue=[NSString stringWithFormat:@"適用中: %.1f℃ → %.0f%% · 最低 %.0f RPM（元の最低 %.0f / 最大 %.0f）",[d[@"temperature"] doubleValue],[d[@"percent"] doubleValue],[d[@"rpm"] doubleValue],[d[@"baseline"] doubleValue],[d[@"maximum"] doubleValue]];
 if(d[@"error"]) { self.curveError=d[@"error"]; self.curveLabel.stringValue=self.curveError; }
 if(!self.curveTask.running) {
  NSData *err=self.curvePipe.fileHandleForReading.readDataToEndOfFile;
  if(!d[@"error"] && self.curveTask.terminationStatus!=0) self.curveLabel.stringValue=err.length?[[NSString alloc] initWithData:err encoding:NSUTF8StringEncoding]:@"適用できませんでした";
  else if([d[@"restored"] boolValue]) self.curveLabel.stringValue=@"カーブを停止しました。元の最低回転数に戻しました。";
  self.curveRequested=NO; self.curveTask=nil; self.applyButton.enabled=YES; self.fanChoice.enabled=YES; self.sensorChoice.enabled=YES;
 }
}

#include "settings-methods.inc"
- (void)applicationWillTerminate:(NSNotification *)n { [self stopCurve]; }
- (void)quit { [self stopCurve]; [NSApp terminate:nil]; }
@end
int main(int argc,const char **argv) { @autoreleasepool {
 if(argc==5 && !strcmp(argv[1],"--curve-helper")) return curveHelper(@(argv[2]),(pid_t)atoi(argv[3]),(uid_t)atoi(argv[4]));
 if(argc>1 && !strcmp(argv[1],"--diagnose")) { NSDictionary *d=@{@"fans":fanSnapshot(),@"gpu":gpuSnapshot()}; NSData *data=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil]; fwrite(data.bytes,1,data.length,stdout); puts(""); return 0; }
 NSApplication *app=NSApplication.sharedApplication; [app setActivationPolicy:NSApplicationActivationPolicyAccessory]; Monitor *monitor=[Monitor new]; app.delegate=monitor; [app run];
 } return 0;
}
