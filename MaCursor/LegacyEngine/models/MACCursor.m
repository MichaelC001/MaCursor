#import "MACCursor.h"
#import "MaCursor-Swift.h"
static const double MACCursorValueLimit = 0x1p53;
static const double MACCursorPointLimit = 0x1p24;

MACCursorScale cursorScaleForScale(CGFloat scale) {
    if (!(scale >= 0.0 && scale < MACCursorValueLimit))
        return MACCursorScaleNone;

    return (MACCursorScale)((NSInteger)scale * 100);
}

@interface MACCursor ()
@property (readwrite, strong) NSMutableDictionary<NSString *, NSBitmapImageRep *> *representations;
- (NSInteger)framesForScale:(MACCursorScale)scale;
- (BOOL)_readFromDictionary:(NSDictionary *)dictionary;
@end

@implementation MACCursor
@dynamic name;

+ (MACCursor *)cursorWithDictionary:(NSDictionary *)dict {
    return [[self alloc] initWithCursorDictionary:dict];
}

- (id)init {
    if ((self = [super init])) {
        self.frameCount      = 1;
        self.frameDuration   = 1.0;
        self.size            = NSZeroSize;
        self.hotSpot         = NSZeroPoint;
        self.identifier      = [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
        self.representations = [NSMutableDictionary dictionary];
    }
    return self;
}

- (id)initWithCursorDictionary:(NSDictionary *)dict {
    if ((self = [self init])) {

        if (![self _readFromDictionary:dict])
            return nil;

    }

    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    MACCursor *cursor = [[MACCursor allocWithZone:zone] init];

    cursor.frameCount      = self.frameCount;
    cursor.frameDuration   = self.frameDuration;
    cursor.size            = self.size;
    cursor.representations = self.representations.mutableCopy;
    cursor.hotSpot         = self.hotSpot;
    cursor.identifier      = self.identifier;

    return cursor;
}

+ (NSSet *)keyPathsForValuesAffectingValueForKey:(NSString *)key {
    NSSet *keyPaths = [super keyPathsForValuesAffectingValueForKey:key];

    if ([key isEqualToString:@"imageWithAllReps"]) {
        keyPaths = [keyPaths setByAddingObjectsFromArray:@[ @"representations" ]];
    } else if ([key isEqualToString:@"name"]) {
        keyPaths = [keyPaths setByAddingObjectsFromArray:@[ @"identifier" ]];
    } else if ([key hasPrefix:@"cursorImage"]) {
        keyPaths = [keyPaths setByAddingObjectsFromArray:@[ [key stringByReplacingCharactersInRange:NSMakeRange(6, 5) withString:@"Rep"] ]];
    }

    return keyPaths;
}

- (BOOL)_readFromDictionary:(NSDictionary *)dictionary {
    if (!dictionary || !dictionary.count)
        return NO;

    NSNumber *frameCount    = [dictionary objectForKey:MACCursorDefinitions.frameCountKey];
    NSNumber *frameDuration = [dictionary objectForKey:MACCursorDefinitions.frameDurationKey];
    NSNumber *hotSpotX      = [dictionary objectForKey:MACCursorDefinitions.hotSpotXKey];
    NSNumber *hotSpotY      = [dictionary objectForKey:MACCursorDefinitions.hotSpotYKey];
    NSNumber *pointsWide    = [dictionary objectForKey:MACCursorDefinitions.pointsWideKey];
    NSNumber *pointsHigh    = [dictionary objectForKey:MACCursorDefinitions.pointsHighKey];
    NSArray *reps           = [dictionary objectForKey:MACCursorDefinitions.representationsKey];

    Class number = NSNumber.class;
    if (![frameCount isKindOfClass:number] || ![frameDuration isKindOfClass:number] || ![hotSpotX isKindOfClass:number] ||
        ![hotSpotY isKindOfClass:number] || ![pointsWide isKindOfClass:number] || ![pointsHigh isKindOfClass:number])
        return NO;

    double frames = frameCount.doubleValue, width = pointsWide.doubleValue, height = pointsHigh.doubleValue;
    BOOL sized = width > 0 && height > 0;
    if (!(frames >= 1 && frames <= MACCursorValueLimit && width >= 0 && width <= MACCursorPointLimit &&
          height >= 0 && height <= MACCursorPointLimit && (sized || !reps.count)))
        return NO;

    self.frameCount    = (NSUInteger)frames;
    self.frameDuration = frameDuration.doubleValue;
    self.hotSpot       = NSMakePoint(hotSpotX.doubleValue, hotSpotY.doubleValue);
    self.size          = NSMakeSize(width, height);

    for (NSData *data in reps) {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:data];
        rep.size = NSMakeSize(self.size.width, self.size.height * self.frameCount);

        [self setRepresentation:rep.retaggedSRGBSpace forScale:cursorScaleForScale(rep.pixelsWide / width)];
    }

    return YES;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *drep = [NSMutableDictionary dictionary];
    drep[MACCursorDefinitions.frameCountKey]    = @(self.frameCount);
    drep[MACCursorDefinitions.frameDurationKey] = @(self.frameDuration);
    drep[MACCursorDefinitions.hotSpotXKey]      = @(self.hotSpot.x);
    drep[MACCursorDefinitions.hotSpotYKey]      = @(self.hotSpot.y);
    drep[MACCursorDefinitions.pointsWideKey]    = @(self.size.width);
    drep[MACCursorDefinitions.pointsHighKey]    = @(self.size.height);

    NSMutableArray *pngs = [NSMutableArray array];
    for (NSString *key in self.representations) {
        NSBitmapImageRep *rep = self.representations[key];
        pngs[pngs.count] = [rep.ensuredSRGBSpace representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    }

    drep[MACCursorDefinitions.representationsKey] = pngs;

    return drep;
}

- (id)valueForUndefinedKey:(NSString *)key {
    if ([key hasPrefix:@"cursorRep"] || [key hasPrefix:@"cursorImage"]) {
        NSString *prefix = [key hasPrefix:@"cursorRep"] ? @"cursorRep" : @"cursorImage";

        NSString *scaleString = [key substringFromIndex:prefix.length];
        CGFloat scale = [scaleString doubleValue] / 100;

        if ([key hasPrefix:@"cursorRep"])
            return [self representationForScale:cursorScaleForScale(scale)];
        else {
            NSImageRep *rep = [self representationForScale:cursorScaleForScale(scale)];
            if (rep) {
                NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(self.size.width, self.size.height * self.frameCount)];
                [image addRepresentation:rep];
                return image;
            }
            return nil;
        }
    }

    return [super valueForUndefinedKey:key];
}

- (void)setValue:(id)value forUndefinedKey:(NSString *)key {
    if ([key hasPrefix:@"cursorRep"] || [key hasPrefix:@"cursorImage"]) {
        NSString *prefix = [key hasPrefix:@"cursorRep"] ? @"cursorRep" : @"cursorImage";
        NSString *scaleString = [key substringFromIndex:prefix.length];
        CGFloat scale = [scaleString doubleValue] / 100;

        if ([key hasPrefix:@"cursorImage"]) {
            value = [(NSImage *)value representations][0];
        }

        [self setRepresentation:value forScale:cursorScaleForScale(scale)];
        return;
    }

    [super setValue:value forUndefinedKey:key];
}

- (void)setRepresentation:(NSBitmapImageRep *)imageRep forScale:(MACCursorScale)scale {
    [self willChangeValueForKey:@"representations"];

    NSString *key = [@"cursorRep" stringByAppendingFormat:@"%lu", scale];
    [self willChangeValueForKey:key];
    if (imageRep)
        [self.representations setObject:imageRep forKey:[NSString stringWithFormat:@"%lu", (unsigned long)scale, nil]];
    else
        [self.representations removeObjectForKey:[NSString stringWithFormat:@"%lu", (unsigned long)scale, nil]];

    if (imageRep && (self.size.width <= 0 || self.size.height <= 0) && imageRep.pixelsWide > 0 && imageRep.pixelsHigh > 0) {
        NSUInteger frameCount = MAX(self.frameCount, 1);
        CGFloat frameHeight = (CGFloat)imageRep.pixelsHigh / frameCount;
        CGFloat pointHeight = round(MACCursorDefinitions.basePointSize * frameHeight / imageRep.pixelsWide);
        self.size = NSMakeSize(MACCursorDefinitions.basePointSize, MAX(1.0, pointHeight));
    }

    [self didChangeValueForKey:key];
    [self didChangeValueForKey:@"representations"];
}

- (void)addFrame:(NSImageRep *)frame forScale:(MACCursorScale)scale {
    NSImageRep *rep = [self representationForScale:scale];
    NSImageRep *newRep = [self.class composeRepresentationWithFrames:@[ rep, frame ]];

    CGFloat scaleFactor = scale / 100.0;
    CGFloat framePixelHeight = self.size.height * scaleFactor;
    NSInteger frames = framePixelHeight > 0 ? lround(newRep.pixelsHigh / framePixelHeight) : 0;

    if (self.frameCount < frames) {
        self.frameCount = frames;
    }

    [self setRepresentation:newRep forScale:scale];
}

+ (NSBitmapImageRep *)composeRepresentationWithFrames:(NSArray<NSBitmapImageRep *> *)frames {
    if (frames.count == 0)
        return nil;
    if (frames.count == 1)
        return frames.firstObject;

    NSUInteger height = [[frames valueForKeyPath:@"@sum.pixelsHigh"] unsignedIntegerValue];
    NSUInteger width = [(NSImageRep *)frames[0] pixelsWide];

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, width, height,
                                              8, 0, cs,
                                              (CGBitmapInfo)kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;

    NSUInteger currentY = 0;
    for (NSInteger idx = frames.count - 1; idx >= 0; idx--) {
        NSBitmapImageRep *rep = frames[idx];
        if (rep.pixelsWide != width) {
            NSLog(@"Can't create representation from images of different widths");
            CGContextRelease(ctx);
            return nil;
        }

        CGImageRef frameImg = [rep CGImage];
        CGContextDrawImage(ctx,
                           CGRectMake(0, currentY, rep.pixelsWide, rep.pixelsHigh),
                           frameImg);
        currentY += rep.pixelsHigh;
    }

    CGImageRef composedImg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!composedImg) return nil;

    NSBitmapImageRep *result = [[NSBitmapImageRep alloc] initWithCGImage:composedImg];
    CGImageRelease(composedImg);
    return result;
}

- (NSInteger)framesForScale:(MACCursorScale)scale {
    NSImageRep *rep = [self representationForScale:scale];
    CGFloat framePixelHeight = self.size.height * (scale / 100.0);
    return rep && framePixelHeight > 0 ? lround(rep.pixelsHigh / framePixelHeight) : 0;
}

- (void)removeRepresentationForScale:(MACCursorScale)scale {
    [self setRepresentation:nil forScale:scale];
}

- (NSImageRep *)representationForScale:(MACCursorScale)scale {
    return self.representations[[NSString stringWithFormat:@"%lu", (unsigned long)scale, nil]];
}

- (NSImageRep *)representationWithScale:(CGFloat)scale {
    return [self representationForScale:cursorScaleForScale(scale)];
}

- (NSImage *)imageWithAllReps {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(self.size.width, self.size.height * self.frameCount)];
    [image addRepresentations:self.representations.allValues];
    return image;
}

- (NSString *)name {
    return [MACCursorDefinitions nameForIdentifier:self.identifier];
}

- (BOOL)isEqualTo:(MACCursor *)object {
    if (![object isKindOfClass:self.class]) {
        return NO;
    }

    BOOL props =  (object.frameCount == self.frameCount &&
                   object.frameDuration == self.frameDuration &&
                   NSEqualSizes(object.size, self.size) &&
                   NSEqualPoints(object.hotSpot, self.hotSpot) &&
                   [object.identifier isEqualToString:self.identifier]);


    return props;
}

- (BOOL)isEqual:(id)object {
    return [self isEqualTo:object];
}

- (NSUInteger)hash {
    NSUInteger h = self.identifier.hash;
    h ^= (NSUInteger)self.frameCount * 31;
    h ^= (NSUInteger)(self.frameDuration * 1000) * 37;
    h ^= (NSUInteger)self.size.width * 41 ^ (NSUInteger)self.size.height * 43;
    h ^= (NSUInteger)self.hotSpot.x * 47 ^ (NSUInteger)self.hotSpot.y * 53;
    return h;
}

@end
