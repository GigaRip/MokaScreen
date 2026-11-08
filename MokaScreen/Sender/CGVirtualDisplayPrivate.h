// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

// Private CoreGraphics virtual display API.
//
// These declarations are not in any SDK header. They were checked against the
// Objective-C runtime of CoreGraphics on macOS 27.2 (property attributes and
// method type encodings), and match the usage in FreeDisplay and Chromium's
// virtual_display_mac_util. The classes are exported from CoreGraphics, so
// declaring them here is enough to link; no entitlement is involved.
//
// Behaviour observed on macOS 27.2:
// - With `hiDPI = 1`, CGVirtualDisplayMode sizes are in points. A 1728×1117
//   mode yields both a 1728×1117 HiDPI mode (3456×2234 pixels) and a 1×
//   1728×1117 mode, and the HiDPI one becomes current. maxPixelsWide/High
//   must cover the HiDPI pixel size or the 2× variant is not offered.
// - Refresh rates of 120 Hz are accepted and reported by CGDisplayModeGetRefreshRate.
// - The display exists only while the CGVirtualDisplay object is alive.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (copy, nonatomic, nullable) void (^terminationHandler)(id _Nullable reason, CGVirtualDisplay * _Nullable display);
@end

@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) unsigned int width;
@property (readonly, nonatomic) unsigned int height;
@property (readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@property (readonly, nonatomic) NSArray *modes;
@property (readonly, nonatomic) unsigned int hiDPI;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END
