/* Wisp's interface — kept apart from the networking on purpose, so the screen
 * can be exercised without depending on WiFi at all. */
#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The same seven states the bridge emits in /state.
 * The order matters: ui_state_from_text() does a linear search by name. */
typedef enum {
    WISP_IDLE = 0,
    WISP_WORKING,
    WISP_TOOL,
    WISP_ASKING,
    WISP_WAITING,
    WISP_DONE,
    WISP_ERROR,
    WISP_OFFLINE,      /* internal: has not connected yet */
    WISP_COUNT
} wisp_state_t;

/* One subscription limit bar (comes from cachedUsageUtilization). */
typedef struct {
    char  label[24];
    int   pct;
    char  resets_in[8];
    char  severity[10];
    bool  active;
    int   elapsed_pct;   /* marca de ritmo medio, 0-100; -1 = nao desenhar */
} wisp_limit_t;

/* How many Claude sessions fit on screen at once. Beyond that the mascots
 * would be too small to communicate anything. */
#define WISP_MAX_SESSIONS 4

/* One Claude Code session = one mascot. */
typedef struct {
    wisp_state_t state;
    char         detail[40];   /* "Bash", "approve plan", "Deploy +1"… */
    char         project[28];
    char         model[24];
    int          age_s;
} wisp_session_t;

typedef struct {
    wisp_session_t sessions[WISP_MAX_SESSIONS];
    int            session_count;

    wisp_limit_t   limits[4];
    int            limit_count;
    int            limits_age_s;     /* -1 = unavailable */
    int            battery_pct;      /* -1 = unknown */
    bool           battery_charging;

    /* —— rest mode ——
     * A motionless mascot tells you nothing. After `rest_s` without a single
     * Claude event, the screen turns into a clock + weather. */
    char        clock[8];       /* "18:08" — already formatted by the bridge */
    char        day[20];        /* "Fri 14 Aug" */
    int         age_s;          /* silence since the last event; -1 = none */
    int         rest_s;         /* threshold; 0 disables rest mode */
    bool        has_weather;
    int         temp, temp_max, temp_min;
    char        condition[24];  /* "partly cloudy" */
    char        icon[12];       /* "sun","moon","cloud","rain","storm","snow","cloudsun","cloudmoon" */
} wisp_data_t;

/* Builds the screen. Must be called with the LVGL mutex held. */
void ui_create(void);

/* Updates the screen. Takes the mutex itself — callable from any task. */
void ui_update(const wisp_data_t *d);

/* Slides one screen sideways: -1 left, +1 right. Stops at the ends.
 * Takes the LVGL mutex itself — callable from any task. */
void ui_swipe(int direction);

/* Converts the JSON "st" field into the enum. Unknown -> WISP_IDLE. */
wisp_state_t ui_state_from_text(const char *s);

#ifdef __cplusplus
}
#endif
