#include <signal.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
static NSArray *defaultCurve(void) { return @[@[@40,@45],@[@55,@55],@[@65,@70],@[@75,@85],@[@85,@100]]; }
static BOOL validCurve(NSArray *points) {
 if(![points isKindOfClass:NSArray.class] || points.count!=5) return NO;
 double lastT=0,lastP=0;
 for(id point in points) { if(![point isKindOfClass:NSArray.class] || [point count]!=2 || ![point[0] isKindOfClass:NSNumber.class] || ![point[1] isKindOfClass:NSNumber.class]) return NO;
 double t=[point[0] doubleValue],p=[point[1] doubleValue]; if(!isfinite(t)||!isfinite(p)||t<30||t>95||t<=lastT||p<0||p>100||p<lastP) return NO; lastT=t; lastP=p; } return YES;
}
static double curveOutput(NSArray *points,double t) {
 if(t>=90) return 100;
 if(t<=[points[0][0] doubleValue]) return [points[0][1] doubleValue];
 for(NSUInteger i=1;i<points.count;i++) { double a=[points[i-1][0] doubleValue],b=[points[i][0] doubleValue]; if(t<=b) return [points[i-1][1] doubleValue]+(t-a)/(b-a)*([points[i][1] doubleValue]-[points[i-1][1] doubleValue]); }
 return [points.lastObject[1] doubleValue];
}
static kern_return_t writeMinimum(io_connect_t c,int fan,double speed,BOOL *didWrite) {
 if(didWrite) *didWrite=NO;
 char key[5]; snprintf(key,sizeof(key),"F%XMn",fan); SMCPacket old;
 if(!smcRead(c,key,&old)) return kIOReturnNotFound;
 SMCPacket in={0},out={0}; in.key=fourCC(key); in.info=old.info; in.command=6;
 if(old.info.type==fourCC("fpe2")&&old.info.size==2) { uint16_t n=(uint16_t)llround(speed*4); in.bytes[0]=n>>8; in.bytes[1]=n&255; }
 else if(old.info.type==fourCC("flt ")&&old.info.size==4) { float f=speed; memcpy(in.bytes,&f,4); }
 else return kIOReturnUnsupported;
 size_t size=sizeof(out); kern_return_t r=IOConnectCallStructMethod(c,2,&in,sizeof(in),&out,&size);
 if(r!=KERN_SUCCESS) return r; if(out.result) return kIOReturnError;
 if(didWrite) *didWrite=YES;
 NSNumber *verify=readNumber(c,key); return verify && fabs(verify.doubleValue-speed)<2 ? KERN_SUCCESS : kIOReturnError;
}
static volatile sig_atomic_t helperStop=0;
static void stopHelper(int s) { (void)s; helperStop=1; }
static void helperStatus(int fd,NSDictionary *d) { NSData *data=[NSJSONSerialization dataWithJSONObject:d options:0 error:nil]; if(fd>=0 && data) { ftruncate(fd,0); pwrite(fd,data.bytes,data.length,0); fsync(fd); } }
static int curveHelper(NSString *config,pid_t parent,uid_t owner) {
 // The helper can only raise F?Mn within the SMC's baseline/maximum limits.
 // Status is written only through a pre-opened regular file owned by the caller.
 NSString *status=[config stringByAppendingString:@".status"];
 int fd=open(status.fileSystemRepresentation,O_WRONLY|O_NOFOLLOW); struct stat st;
 if(fd<0 || fstat(fd,&st)!=0 || !S_ISREG(st.st_mode)||st.st_uid!=owner) { if(fd>=0) close(fd); return 2; }
 signal(SIGTERM,stopHelper); signal(SIGINT,stopHelper); signal(SIGHUP,stopHelper);
 io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC")); io_connect_t c=0;
 kern_return_t r=service?IOServiceOpen(service,mach_task_self(),0,&c):kIOReturnNotFound; if(service) IOObjectRelease(service);
 if(r!=KERN_SUCCESS) { helperStatus(fd,@{@"error":@"SMCに接続できません"}); close(fd); return 3; }
 int selected=-1; double baseline=0,maximum=0; BOOL changed=NO; NSString *error=nil;
 while(!helperStop && kill(parent,0)==0) { @autoreleasepool {
  NSDictionary *d=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:config]?:[NSData data] options:0 error:nil];
  if(![d isKindOfClass:NSDictionary.class] || ![d[@"enabled"] boolValue] || fabs(NSDate.date.timeIntervalSince1970-[d[@"heartbeat"] doubleValue])>12) break;
  NSArray *points=d[@"points"]; if(!validCurve(points)) { error=@"温度カーブが不正です"; break; }
  int fan=[d[@"fan"] intValue]; NSNumber *count=readNumber(c,"FNum");
  if(!count || fan<0 || fan>=count.intValue || fan>=16) { error=@"選択したファンが見つかりません"; break; }
  if(selected<0) { char key[5]; snprintf(key,sizeof(key),"F%XMn",fan); NSNumber *lo=readNumber(c,key); snprintf(key,sizeof(key),"F%XMx",fan); NSNumber *hi=readNumber(c,key);
   if(!lo||!hi||lo.doubleValue<=0||hi.doubleValue<lo.doubleValue||hi.doubleValue>16000) { error=@"最低・最高回転数が取得できないため適用できません"; break; }
   selected=fan; baseline=lo.doubleValue; maximum=hi.doubleValue;
  } else if(fan!=selected) { error=@"ファンを変更する前に自動制御に戻してください"; break; }
  NSDictionary *snapshot=fanSnapshot(); NSNumber *cpu=snapshot[@"cpuTemperature"]; double temp=cpu?cpu.doubleValue:NAN;
  NSString *sensor=d[@"sensor"]?:@"CPU";
  if(![sensor isEqualToString:@"CPU"]) { double gtemp=NAN; for(NSDictionary *g in gpuSnapshot()) { NSNumber *t=g[@"stats"][@"Temperature(C)"]; if([t isKindOfClass:NSNumber.class] && t.doubleValue>0&&t.doubleValue<130) gtemp=isnan(gtemp)?t.doubleValue:fmax(gtemp,t.doubleValue); }
   temp=[sensor isEqualToString:@"GPU"]?gtemp:(isnan(temp)||isnan(gtemp)?NAN:fmax(temp,gtemp));
  }
  if(!isfinite(temp)) { error=@"選択した温度センサーが取得できません。元の最低回転数に戻します"; break; }
  double output=curveOutput(points,temp); double rpm=fmax(baseline,fmin(maximum,maximum*output/100));
  BOOL didWrite=NO; r=writeMinimum(c,selected,rpm,&didWrite); changed|=didWrite;
  if(r!=KERN_SUCCESS) { error=[NSString stringWithFormat:@"回転数を適用できません (0x%08x)",r]; break; }
  helperStatus(fd,@{@"active":@YES,@"temperature":@(temp),@"percent":@(output),@"rpm":@(rpm),@"baseline":@(baseline),@"maximum":@(maximum)});
 }
 sleep(1); }
 if(changed) { r=writeMinimum(c,selected,baseline,NULL); if(r!=KERN_SUCCESS) error=[NSString stringWithFormat:@"元の最低回転数への復元失敗 (0x%08x)。再起動してください",r]; }
 helperStatus(fd,error?@{@"active":@NO,@"error":error}:@{@"active":@NO,@"restored":@YES}); IOServiceClose(c); close(fd); return error?1:0;
}
@class CurveView;
@protocol CurveViewDelegate <NSObject>
- (void)curveChanged;
@end
@interface CurveView : NSView
@property NSMutableArray *points;
@property NSInteger dragged;
@property (weak) id<CurveViewDelegate> curveDelegate;
@end
@implementation CurveView
- (instancetype)initWithFrame:(NSRect)f { if((self=[super initWithFrame:f])) { self.points=[defaultCurve() mutableCopy]; self.dragged=-1; } return self; }
- (NSRect)plot { return NSMakeRect(54,38,self.bounds.size.width-78,self.bounds.size.height-65); }
- (NSPoint)position:(NSArray *)p { NSRect r=self.plot; return NSMakePoint(r.origin.x+([p[0] doubleValue]-30)/65*r.size.width,r.origin.y+[p[1] doubleValue]/100*r.size.height); }
- (void)drawRect:(NSRect)dirty {
 [NSColor.windowBackgroundColor setFill]; NSRectFill(self.bounds); NSRect r=self.plot;
 NSDictionary *attrs=@{NSFontAttributeName:[NSFont systemFontOfSize:11],NSForegroundColorAttributeName:NSColor.secondaryLabelColor};
 for(int t=30;t<=90;t+=10) { double x=r.origin.x+(t-30)/65.0*r.size.width; [NSColor.separatorColor setStroke]; NSBezierPath *p=[NSBezierPath bezierPath]; [p moveToPoint:NSMakePoint(x,r.origin.y)]; [p lineToPoint:NSMakePoint(x,NSMaxY(r))]; [p stroke]; [[NSString stringWithFormat:@"%d℃",t] drawAtPoint:NSMakePoint(x-12,15) withAttributes:attrs]; }
 for(int v=0;v<=100;v+=20) { double y=r.origin.y+v/100.0*r.size.height; [NSColor.separatorColor setStroke]; NSBezierPath *p=[NSBezierPath bezierPath]; [p moveToPoint:NSMakePoint(r.origin.x,y)]; [p lineToPoint:NSMakePoint(NSMaxX(r),y)]; [p stroke]; [[NSString stringWithFormat:@"%d%%",v] drawAtPoint:NSMakePoint(14,y-6) withAttributes:attrs]; }
 [NSColor.controlAccentColor setStroke]; NSBezierPath *line=[NSBezierPath bezierPath]; line.lineWidth=3;
 for(NSUInteger i=0;i<self.points.count;i++) { NSPoint p=[self position:self.points[i]]; if(i==0) [line moveToPoint:p]; else [line lineToPoint:p]; } [line stroke];
 for(NSArray *point in self.points) { NSPoint p=[self position:point]; [NSColor.controlAccentColor setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x-6,p.y-6,12,12)] fill]; [[NSString stringWithFormat:@"%@℃ / %@%%",point[0],point[1]] drawAtPoint:NSMakePoint(fmin(p.x-28,NSMaxX(r)-70),fmin(p.y+10,NSMaxY(r)+4)) withAttributes:attrs]; }
}
- (void)mouseDown:(NSEvent *)e { NSPoint p=[self convertPoint:e.locationInWindow fromView:nil]; self.dragged=-1; for(NSUInteger i=0;i<self.points.count;i++) { NSPoint q=[self position:self.points[i]]; if(hypot(p.x-q.x,p.y-q.y)<18) { self.dragged=i; break; } } }
- (void)mouseDragged:(NSEvent *)e { if(self.dragged<0) return; NSRect r=self.plot; NSPoint p=[self convertPoint:e.locationInWindow fromView:nil]; NSInteger i=self.dragged;
 double low=i>0?[self.points[i-1][0] doubleValue]+1:30,high=i+1<(NSInteger)self.points.count?[self.points[i+1][0] doubleValue]-1:95;
 double bottom=i>0?[self.points[i-1][1] doubleValue]:0,top=i+1<(NSInteger)self.points.count?[self.points[i+1][1] doubleValue]:100;
 self.points[i]=@[@(round(fmax(low,fmin(high,30+(p.x-r.origin.x)/r.size.width*65)))),@(round(fmax(bottom,fmin(top,(p.y-r.origin.y)/r.size.height*100))))]; self.needsDisplay=YES; [self.curveDelegate curveChanged];
}
- (void)mouseUp:(NSEvent *)e { self.dragged=-1; }
@end
