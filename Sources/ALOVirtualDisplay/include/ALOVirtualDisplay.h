#ifndef ALO_VIRTUAL_DISPLAY_H
#define ALO_VIRTUAL_DISPLAY_H

#include <CoreGraphics/CGDirectDisplay.h>
#include <stdbool.h>

typedef struct ALOVirtualDisplayHandle ALOVirtualDisplayHandle;

// Uses a private macOS API. Returns NULL when the current OS does not expose a
// compatible implementation; callers must treat this as an optional feature.
ALOVirtualDisplayHandle *ALOVirtualDisplayCreate(void);
CGDirectDisplayID ALOVirtualDisplayGetDisplayID(const ALOVirtualDisplayHandle *handle);
void ALOVirtualDisplayDestroy(ALOVirtualDisplayHandle *handle);
bool ALOVirtualDisplayIsSupported(void);

#endif
