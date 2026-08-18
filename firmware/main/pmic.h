/* Battery charge, read from the AXP2101 — the board's power management chip.
 *
 * Split out of main for the same reason as the ui: the source of the reading
 * can be swapped without touching networking or the screen. */
#pragma once

#include <stdbool.h>
#include "driver/i2c_master.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Opens the AXP2101 on the BSP's bus and checks the chip identity.
 * False = no PMIC; the rest of the firmware carries on with no battery
 * indicator. */
bool pmic_start(i2c_master_bus_handle_t bus);

/* Charge in 0-100 and whether it is charging. False = the reading is not
 * trustworthy right now (I2C failed, or the gauge returned an out-of-range
 * value) — in that case the pointers are left untouched and the caller keeps
 * whatever it already had. */
bool pmic_read(int *pct, bool *charging);

/* Raw read of one register. The AXP2101 carries more than the charge — the
 * board's power button, for instance, arrives as an interrupt bit and not as
 * a GPIO. False = I2C failed or the PMIC did not come up. */
bool pmic_read_reg(uint8_t reg, uint8_t *value);

#ifdef __cplusplus
}
#endif
