// Private IOKit functions for talking to displays behind Apple Silicon's
// Display Coprocessor (DCP). Not in the public SDK; signatures are the ones
// used by the community (zhuowei's IOAVService_Private.h, force-edid).

#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

CF_ASSUME_NONNULL_BEGIN

typedef CFTypeRef IOAVServiceRef;

extern IOAVServiceRef _Nullable IOAVServiceCreateWithService(CFAllocatorRef _Nullable allocator,
                                                             io_service_t service) CF_RETURNS_RETAINED;

/// Copies the EDID the display is currently using (the virtual one, when set).
extern IOReturn IOAVServiceCopyEDID(IOAVServiceRef service, CFDataRef _Nullable *_Nullable edid);

/// mode 1 replaces the display's EDID with `edid` until it is disconnected;
/// mode 0 (with NULL) goes back to the display's own EDID.
extern IOReturn IOAVServiceSetVirtualEDIDMode(IOAVServiceRef service, uint32_t mode, CFDataRef _Nullable edid);

CF_ASSUME_NONNULL_END
