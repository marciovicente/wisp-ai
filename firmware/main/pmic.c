/* AXP2101 — battery charge.
 *
 * WHY SPEAK I2C BY HAND
 * ---------------------
 * Waveshare's BSP does not cover the AXP2101. It does not even pretend to: its
 * comment about the I2C bus lists a QMA7981 IMU and an OV2640 camera, neither
 * of which exists on this board. It is copied from another product. So the map
 * below did not come from the BSP or from memory — it came from reading the
 * board.
 *
 * HOW THE MAP WAS CHECKED
 * -----------------------
 * A bus scan returned 0x18 0x34 0x40 0x51 0x5A 0x6B. At 0x34, register 0x03
 * answered 0x4A, which is the AXP2101's ID — identity confirmed, not an
 * address guessed at.
 *
 * With the board on the cable and the battery installed, the reading was:
 *
 *   0x00 = 0x38   VBUS present, BATFET on, battery detected
 *   0x01 = 0x32   charging, constant current
 *   0xA4 = 0x4E   78%
 *   0x34/35 = 0x0F 0xC1  ->  4033 mV
 *
 * The last two are the cross-check that matters: 78% and 4.03V are consistent
 * with each other for a lithium cell that is charging. If the charge register
 * were a different one, the numbers would not agree by accident.
 */

#include "pmic.h"
#include "esp_log.h"

static const char *TAG = "pmic";

#define AXP_ADDRESS     0x34
#define AXP_ID          0x03   /* reads 0x4A on the AXP2101 */
#define AXP_ID_EXPECTED 0x4A
#define AXP_STATUS1     0x00   /* bit 3: battery present */
#define AXP_STATUS2     0x01   /* bits 6-5: 01 = charging */
#define AXP_CHARGE      0xA4   /* internal gauge, 0-100 */

static i2c_master_dev_handle_t s_axp;

static bool read_reg(uint8_t reg, uint8_t *v)
{
    return i2c_master_transmit_receive(s_axp, &reg, 1, v, 1, 200) == ESP_OK;
}

bool pmic_start(i2c_master_bus_handle_t bus)
{
    if (!bus) {
        ESP_LOGW(TAG, "no I2C bus — no battery indicator");
        return false;
    }
    const i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = AXP_ADDRESS,
        .scl_speed_hz = 100000,
    };
    if (i2c_master_bus_add_device(bus, &cfg, &s_axp) != ESP_OK) {
        ESP_LOGW(TAG, "0x%02X did not open — no battery indicator", AXP_ADDRESS);
        return false;
    }
    /* Check the ID instead of trusting the address: 0x34 is a common address,
     * and a wrong chip answering there would give plausible, false numbers —
     * worse than no indicator at all. */
    uint8_t id = 0;
    if (!read_reg(AXP_ID, &id) || id != AXP_ID_EXPECTED) {
        ESP_LOGW(TAG, "0x%02X is not an AXP2101 (ID 0x%02X) — no battery", AXP_ADDRESS, id);
        i2c_master_bus_rm_device(s_axp);
        s_axp = NULL;
        return false;
    }
    ESP_LOGI(TAG, "AXP2101 ready");
    return true;
}

bool pmic_read_reg(uint8_t reg, uint8_t *value)
{
    return s_axp && value && read_reg(reg, value);
}

bool pmic_write_reg(uint8_t reg, uint8_t value)
{
    if (!s_axp) return false;
    const uint8_t buf[2] = {reg, value};
    return i2c_master_transmit(s_axp, buf, sizeof(buf), 200) == ESP_OK;
}

bool pmic_read(int *pct, bool *charging)
{
    if (!s_axp) return false;

    uint8_t s1 = 0, s2 = 0, charge = 0;
    if (!read_reg(AXP_STATUS1, &s1) || !read_reg(AXP_STATUS2, &s2) ||
        !read_reg(AXP_CHARGE, &charge)) {
        return false;
    }
    /* With no battery connected the gauge returns a number anyway, and it
     * means nothing. Better to admit we do not know. */
    if (!(s1 & (1 << 3))) return false;
    if (charge > 100) return false;

    *pct = charge;
    *charging = ((s2 >> 5) & 0x03) == 0x01;
    return true;
}
