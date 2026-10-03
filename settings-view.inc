@interface SettingsBackgroundView : NSView
@end
@implementation SettingsBackgroundView
- (void)drawRect:(NSRect)rect { [NSColor.windowBackgroundColor setFill]; NSRectFill(self.bounds); }
@end
@interface HistoryView : NSView
@property NSArray *samples;
@end
@implementation HistoryView
- (void)drawRect:(NSRect)r {
 [NSColor.windowBackgroundColor setFill]; NSRectFill(self.bounds);
 NSDictionary *text=@{NSFontAttributeName:[NSFont systemFontOfSize:11],NSForegroundColorAttributeName:NSColor.secondaryLabelColor};
 [@"CPU（青） / GPU（緑） · 最新120回の記録" drawAtPoint:NSMakePoint(12,self.bounds.size.height-24) withAttributes:text];
 NSRect plot=NSMakeRect(40,22,self.bounds.size.width-55,self.bounds.size.height-55);
 for(int n=0;n<=100;n+=50) { double y=plot.origin.y+n/100.0*plot.size.height; [NSColor.separatorColor setStroke]; NSBezierPath *p=[NSBezierPath bezierPath]; [p moveToPoint:NSMakePoint(plot.origin.x,y)]; [p lineToPoint:NSMakePoint(NSMaxX(plot),y)]; [p stroke]; [[NSString stringWithFormat:@"%d",n] drawAtPoint:NSMakePoint(8,y-6) withAttributes:text]; }
 NSArray *keys=@[@"cpu",@"gpu"]; NSArray *colors=@[NSColor.systemBlueColor,NSColor.systemGreenColor];
 for(int j=0;j<2;j++) { NSBezierPath *p=[NSBezierPath bezierPath]; p.lineWidth=2; BOOL connected=NO;
  for(NSUInteger i=0;i<self.samples.count;i++) { id v=self.samples[i][keys[j]]; if(![v isKindOfClass:NSNumber.class]) { connected=NO; continue; } NSPoint q=NSMakePoint(plot.origin.x+i/119.0*plot.size.width,plot.origin.y+[v doubleValue]/100.0*plot.size.height); if(connected) [p lineToPoint:q]; else [p moveToPoint:q]; connected=YES; }
  [colors[j] setStroke]; [p stroke];
 }
 if(!self.samples.count) [@"履歴がオフ、または測定待ちです" drawAtPoint:NSMakePoint(70,55) withAttributes:text];
}
@end
static NSArray *coreLoads(NSArray *old,NSArray **next) {
 natural_t cores=0; processor_info_array_t info=NULL; mach_msg_type_number_t count=0; mach_port_t host=mach_host_self();
 kern_return_t r=host_processor_info(host,PROCESSOR_CPU_LOAD_INFO,&cores,&info,&count); mach_port_deallocate(mach_task_self(),host);
 if(r!=KERN_SUCCESS) { *next=nil; return @[]; }
 NSMutableArray *ticks=[NSMutableArray array],*loads=[NSMutableArray array];
 for(natural_t i=0;i<cores;i++) {
  uint64_t total=0; for(int j=0;j<CPU_STATE_MAX;j++) total+=(uint32_t)info[i*CPU_STATE_MAX+j]; uint64_t idle=(uint32_t)info[i*CPU_STATE_MAX+CPU_STATE_IDLE];
  [ticks addObject:@[@(total),@(idle)]];
  if(i<old.count && total>[old[i][0] unsignedLongLongValue] && idle>=[old[i][1] unsignedLongLongValue]) {
   double value=100.0*(1.0-(double)(idle-[old[i][1] unsignedLongLongValue])/(total-[old[i][0] unsignedLongLongValue])); [loads addObject:@(fmax(0,fmin(100,value)))];
  } else [loads addObject:NSNull.null];
 }
 vm_deallocate(mach_task_self(),(vm_address_t)info,count*sizeof(integer_t)); *next=ticks; return loads;
}
