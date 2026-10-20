#ifndef SWEEP_NATIVE_H
#define SWEEP_NATIVE_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>

/// The NVMe "SMART / Health Information" log (NVM Express 1.0c, 5.10.1.2), with the 128-bit counters cut to
/// their low 64 bits (no drive comes near 2^64 of anything).
typedef struct {
    uint8_t criticalWarning;
    uint16_t temperatureKelvin;
    uint8_t availableSpare;
    uint8_t availableSpareThreshold;
    uint8_t percentageUsed;
    uint64_t dataUnitsRead;
    uint64_t dataUnitsWritten;
    uint64_t powerCycles;
    uint64_t powerOnHours;
    uint64_t unsafeShutdowns;
    uint64_t mediaErrors;
    uint64_t errorLogEntries;
} SweepNVMeHealth;

/// Reads the health log of a block storage device whose registry entry says "NVMe SMART Capable", through the
/// read-only NVMe SMART user client (no administrator rights needed). Returns 0 on success, an IOReturn otherwise.
int32_t SweepReadNVMeHealth(io_service_t service, SweepNVMeHealth *health);

/// The directory-services UUID of a user (what names their background item database). Returns 0 on success.
int SweepUserUUID(uid_t user, unsigned char uuid[16]);

#endif
