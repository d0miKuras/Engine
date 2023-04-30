#include "application.h"
#include "core/logger.h"
#include "core/sfmemory.h"
#include "game_definitions.h"
#include "platform/platform.h"

application_state* application_create(game* game_instance) {
  // Init subsystems
  logging_initialize();

  application_state* state =
      platform_allocate(sizeof(application_state), FALSE);
  if (!platform_init(&state->plat_state, game_instance->app_config.name,
                     game_instance->app_config.x, game_instance->app_config.y,
                     game_instance->app_config.width,
                     game_instance->app_config.height, 0)) {
    SF_FATAL("FAILED TO CREATE APP!");
    return FALSE;
  }
  state->is_running = TRUE;
  return state;
}

void application_run(application_state* state) {
  while (state->is_running) {
    if (!platform_update_internal_state(&state->plat_state)) {
      state->is_running = FALSE;
    }
  }
  state->is_running = FALSE;

  // Cleanup
  application_shutdown(state);
  logging_shutdown();
  memory_shutdown();
}

void application_shutdown(application_state* state) {
  if (state) {
    platform_shutdown(&state->plat_state);
    platform_free(state, FALSE);
  }
}