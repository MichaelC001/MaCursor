#pragma once
#include "CGSPrivateConnection.h"
#import <ApplicationServices/ApplicationServices.h>
typedef int CGSCursorID;
CG_EXTERN CGError CoreCursorUnregisterAll(CGSConnectionID cid);
CG_EXTERN CGError CoreCursorSet(CGSConnectionID cid, CGSCursorID cursorID);
CG_EXTERN CGError CoreCursorCopyImages(CGSConnectionID cid, CGSCursorID cursorID, CFArrayRef *images, CGSize *imageSize, CGPoint *hotSpot, NSUInteger *frameCount, CGFloat *frameDuration);
CG_EXTERN CGError CGSCopyRegisteredCursorImages(CGSConnectionID cid, char *cursorName, CGSize *imageSize, CGPoint *hotSpot, NSUInteger *frameCount, CGFloat *frameDuration, CFArrayRef *imageArray);
CG_EXTERN CGError CGSRegisterCursorWithImages(CGSConnectionID cid, char *cursorName, bool setGlobally, bool instantly, CGSize cursorSize, CGPoint hotspot, NSUInteger frameCount, CGFloat frameDuration, CFArrayRef imageArray, int *seed);
CG_EXTERN CGError CGSSetSystemDefinedCursor(CGSConnectionID cid, CGSCursorID cursor);
CG_EXTERN void CGSSetDockCursorOverride(CGSConnectionID cid, bool flag);
CG_EXTERN CGError CGSGetRegisteredCursorDataSize(CGSConnectionID cid, char *cursorName, size_t *size);
CG_EXTERN CGError CGSSetRegisteredCursor(CGSConnectionID cid, char *cursorName, int *seed);
CG_EXTERN CGError CGSShowCursor(CGSConnectionID cid);
CG_EXTERN CGError CGSHideCursor(CGSConnectionID cid);
