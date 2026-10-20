#include "SweepNative.h"
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <membership.h>

int SweepUserUUID(uid_t user, unsigned char uuid[16]) {
    return mbr_uid_to_uuid(user, uuid);
}

int32_t SweepReadNVMeHealth(io_service_t service, SweepNVMeHealth *health) {
    if (health == NULL) return kIOReturnBadArgument;
    memset(health, 0, sizeof *health);
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t result = IOCreatePlugInInterfaceForService(service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID,
                                                             &plugin, &score);
    if (result != KERN_SUCCESS || plugin == NULL) return result == KERN_SUCCESS ? kIOReturnError : result;

    IONVMeSMARTInterface **smart = NULL;
    HRESULT queried = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    if (queried != S_OK || smart == NULL) {
        IODestroyPlugInInterface(plugin);
        return kIOReturnUnsupported;
    }
    NVMeSMARTData data;
    memset(&data, 0, sizeof data);
    IOReturn read = (*smart)->SMARTReadData(smart, &data);
    if (read == kIOReturnSuccess) {
        health->criticalWarning = data.CRITICAL_WARNING;
        health->temperatureKelvin = data.TEMPERATURE;
        health->availableSpare = data.AVAILABLE_SPARE;
        health->availableSpareThreshold = data.AVAILABLE_SPARE_THRESHOLD;
        health->percentageUsed = data.PERCENTAGE_USED;
        health->dataUnitsRead = data.DATA_UNITS_READ[0];
        health->dataUnitsWritten = data.DATA_UNITS_WRITTEN[0];
        health->powerCycles = data.POWER_CYCLES[0];
        health->powerOnHours = data.POWER_ON_HOURS[0];
        health->unsafeShutdowns = data.UNSAFE_SHUTDOWNS[0];
        health->mediaErrors = data.MEDIA_ERRORS[0];
        health->errorLogEntries = data.NUM_ERROR_INFO_LOG_ENTRIES[0];
    }
    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
    return read;
}
