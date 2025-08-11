#include <android_native_app_glue.h>
#include <android/sensor.h>

extern "C" {

void call_souce_process(android_app *state, android_poll_source *s) {
  s->process(state, s);
}

const float* get_acceleration(const ASensorEvent *event)
{
  return &event->acceleration.x;
}

}
