// TurboModule `SmartWear` (iOS): lớp ObjC++ mỏng nối đặc tả codegen với phần Swift `SmartWearImpl`.
#import <RNSmartWearSpec/RNSmartWearSpec.h>
#import <React/RCTBridgeModule.h>

#if __has_include("react_native_wearlink/react_native_wearlink-Swift.h")
#import "react_native_wearlink/react_native_wearlink-Swift.h"
#else
#import "react_native_wearlink-Swift.h"
#endif

@interface SmartWear : NativeSmartWearSpecBase <NativeSmartWearSpec>

@end

@implementation SmartWear {
  SmartWearImpl *_impl;
}

RCT_EXPORT_MODULE(SmartWear)

- (instancetype)init {
  if (self = [super init]) {
    _impl = [SmartWearImpl new];
    __weak SmartWear *weakSelf = self;
    _impl.emit = ^(NSString *name, NSDictionary *body) {
      SmartWear *strongSelf = weakSelf;
      if (!strongSelf) return;
      if ([name isEqualToString:@"onDevicesChanged"]) [strongSelf emitOnDevicesChanged:body];
      else if ([name isEqualToString:@"onDiscovered"]) [strongSelf emitOnDiscovered:body];
      else if ([name isEqualToString:@"onReading"]) [strongSelf emitOnReading:body];
      else if ([name isEqualToString:@"onFindPhone"]) [strongSelf emitOnFindPhone:body];
      else if ([name isEqualToString:@"onSyncProgress"]) [strongSelf emitOnSyncProgress:body];
      else if ([name isEqualToString:@"onEvent"]) [strongSelf emitOnEvent:body];
    };
  }
  return self;
}

+ (BOOL)requiresMainQueueSetup { return NO; }

- (void)invalidate { [_impl invalidate]; }

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:(const facebook::react::ObjCTurboModule::InitParams &)params {
  return std::make_shared<facebook::react::NativeSmartWearSpecJSI>(params);
}

#define RESOLVE ^(id v) { resolve(v); }
#define REJECT ^(NSString *code, NSString *msg) { reject(code, msg, nil); }

- (void)start { [_impl start]; }
- (void)startScan:(double)seconds { [_impl startScan:seconds]; }
- (void)stopScan { [_impl stopScan]; }
- (void)getDiscovered:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject { [_impl getDiscovered:RESOLVE reject:REJECT]; }
- (void)getDevices:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject { [_impl getDevices:RESOLVE reject:REJECT]; }

- (void)connect:(NSString *)deviceId keep:(BOOL)keep resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  [_impl connect:deviceId keep:keep resolve:RESOLVE reject:REJECT];
}
- (void)disconnect:(NSString *)deviceId { [_impl disconnect:deviceId]; }
- (void)forget:(NSString *)deviceId { [_impl forget:deviceId]; }
- (void)setKeepConnected:(NSString *)deviceId keep:(BOOL)keep { [_impl setKeepConnected:deviceId keep:keep]; }
- (void)submitPairingCode:(NSString *)deviceId code:(NSString *)code { [_impl submitPairingCode:deviceId code:code]; }

- (void)measure:(NSString *)deviceId capability:(NSString *)capability { [_impl measure:deviceId capability:capability]; }
- (void)stopMeasure:(NSString *)deviceId capability:(NSString *)capability { [_impl stopMeasure:deviceId capability:capability]; }
- (void)syncHistory:(NSString *)deviceId days:(double)days resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  [_impl syncHistory:deviceId days:days resolve:RESOLVE reject:REJECT];
}

- (void)getControls:(NSString *)deviceId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  [_impl getControls:deviceId resolve:RESOLVE reject:REJECT];
}
- (void)setControl:(NSString *)deviceId controlId:(NSString *)controlId value:(NSDictionary *)value
           resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  [_impl setControl:deviceId controlId:controlId value:value resolve:RESOLVE reject:REJECT];
}
- (void)runAction:(NSString *)deviceId actionId:(NSString *)actionId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  [_impl runAction:deviceId actionId:actionId resolve:RESOLVE reject:REJECT];
}

- (void)setWeather:(NSString *)deviceId forecast:(NSDictionary *)forecast resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  [_impl setWeather:deviceId forecast:forecast resolve:RESOLVE reject:REJECT];
}
- (void)syncContacts:(NSString *)deviceId contacts:(NSArray *)contacts resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  [_impl syncContacts:deviceId contacts:contacts resolve:RESOLVE reject:REJECT];
}
- (void)getCallBluetoothState:(NSString *)deviceId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  [_impl getCallBluetoothState:deviceId resolve:RESOLVE reject:REJECT];
}
- (void)pairCallBluetooth:(NSString *)deviceId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  [_impl pairCallBluetooth:deviceId resolve:RESOLVE reject:REJECT];
}
- (void)setPhoneRinging:(NSString *)deviceId ringing:(BOOL)ringing resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  [_impl setPhoneRinging:deviceId ringing:ringing resolve:RESOLVE reject:REJECT];
}

- (void)invoke:(NSString *)method deviceId:(NSString *)deviceId args:(NSDictionary *)args
       resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  [_impl invoke:method deviceId:deviceId args:args resolve:RESOLVE reject:REJECT];
}

@end
