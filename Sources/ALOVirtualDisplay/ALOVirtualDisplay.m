#import "ALOVirtualDisplay.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@interface NSObject (ALOVirtualDisplayPrivateCalls)
- (instancetype)initWithDescriptor:(id)descriptor;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
- (BOOL)applySettings:(id)settings;
- (unsigned int)displayID;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
- (void)setName:(NSString *)name;
- (void)setMaxPixelsWide:(NSUInteger)width;
- (void)setMaxPixelsHigh:(NSUInteger)height;
- (void)setSizeInMillimeters:(CGSize)size;
- (void)setVendorID:(unsigned int)value;
- (void)setProductID:(unsigned int)value;
- (void)setSerialNum:(unsigned int)value;
- (void)setHiDPI:(BOOL)value;
- (void)setModes:(NSArray *)modes;
@end

struct ALOVirtualDisplayHandle {
    CFTypeRef display;
    CGDirectDisplayID displayID;
};

static BOOL ALOClassesAvailable(void) {
    return NSClassFromString(@"CGVirtualDisplay") != Nil &&
           NSClassFromString(@"CGVirtualDisplayDescriptor") != Nil &&
           NSClassFromString(@"CGVirtualDisplayMode") != Nil &&
           NSClassFromString(@"CGVirtualDisplaySettings") != Nil;
}

bool ALOVirtualDisplayIsSupported(void) {
    return ALOClassesAvailable();
}

ALOVirtualDisplayHandle *ALOVirtualDisplayCreate(void) {
    @autoreleasepool {
        @try {
            if (!ALOClassesAvailable()) return NULL;

            id descriptor = [NSClassFromString(@"CGVirtualDisplayDescriptor") new];
            dispatch_queue_t queue = dispatch_queue_create("in.werai.virtual-display", DISPATCH_QUEUE_SERIAL);
            [descriptor setDispatchQueue:queue];
            [descriptor setName:@"ALO Display"];
            [descriptor setMaxPixelsWide:1920];
            [descriptor setMaxPixelsHigh:1080];
            [descriptor setSizeInMillimeters:CGSizeMake(509, 286)];
            [descriptor setVendorID:0x414C4F];
            [descriptor setProductID:0x0001];
            [descriptor setSerialNum:0x414C4F01];

            id display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
            if (display == nil) return NULL;
            id mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                initWithWidth:1920 height:1080 refreshRate:60.0];
            id settings = [NSClassFromString(@"CGVirtualDisplaySettings") new];
            [settings setHiDPI:NO];
            [settings setModes:@[mode]];
            if (![display applySettings:settings]) return NULL;

            ALOVirtualDisplayHandle *handle = calloc(1, sizeof(*handle));
            if (handle == NULL) return NULL;
            handle->display = CFBridgingRetain(display);
            handle->displayID = [display displayID];
            return handle;
        } @catch (__unused NSException *exception) {
            // This is an unsupported private API. Any selector or ABI change
            // must degrade to a user-facing unsupported error, never crash ALO.
            return NULL;
        }
    }
}

CGDirectDisplayID ALOVirtualDisplayGetDisplayID(const ALOVirtualDisplayHandle *handle) {
    return handle == NULL ? kCGNullDirectDisplay : handle->displayID;
}

void ALOVirtualDisplayDestroy(ALOVirtualDisplayHandle *handle) {
    if (handle == NULL) return;
    if (handle->display != NULL) CFRelease(handle->display);
    free(handle);
}
