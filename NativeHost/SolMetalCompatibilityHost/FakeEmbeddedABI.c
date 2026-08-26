#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static const char *events[16];
static int event_count;
static int event_index;
static int report_written;
static int terminated;
static int environment_ready_at_load;
static char backend_at_load[64];
static char benchmark_output_at_load[4096];
static char benchmark_label_at_load[128];
static char benchmark_warmup_at_load[64];
static char benchmark_duration_at_load[64];

static void copy_environment_value(const char *name, char *destination, size_t capacity) {
    const char *value = getenv(name);
    snprintf(destination, capacity, "%s", value == NULL ? "" : value);
}

__attribute__((constructor))
static void capture_environment_at_library_load(void) {
    copy_environment_value(
        "SOL_METAL_GAL_BACKEND",
        backend_at_load,
        sizeof(backend_at_load)
    );
    copy_environment_value(
        "SOL_BENCHMARK_OUTPUT",
        benchmark_output_at_load,
        sizeof(benchmark_output_at_load)
    );
    copy_environment_value(
        "SOL_BENCHMARK_LABEL",
        benchmark_label_at_load,
        sizeof(benchmark_label_at_load)
    );
    copy_environment_value(
        "SOL_BENCHMARK_WARMUP_SECONDS",
        benchmark_warmup_at_load,
        sizeof(benchmark_warmup_at_load)
    );
    copy_environment_value(
        "SOL_BENCHMARK_DURATION_SECONDS",
        benchmark_duration_at_load,
        sizeof(benchmark_duration_at_load)
    );

    environment_ready_at_load =
        strcmp(backend_at_load, "1") == 0 &&
        benchmark_output_at_load[0] != '\0' &&
        strcmp(benchmark_label_at_load, "embedded-host-solmetal") == 0 &&
        benchmark_warmup_at_load[0] != '\0' &&
        benchmark_duration_at_load[0] != '\0';
}

static int environment_unchanged_since_load(void) {
    return
        strcmp(getenv("SOL_METAL_GAL_BACKEND") ?: "", backend_at_load) == 0 &&
        strcmp(getenv("SOL_BENCHMARK_OUTPUT") ?: "", benchmark_output_at_load) == 0 &&
        strcmp(getenv("SOL_BENCHMARK_LABEL") ?: "", benchmark_label_at_load) == 0 &&
        strcmp(getenv("SOL_BENCHMARK_WARMUP_SECONDS") ?: "", benchmark_warmup_at_load) == 0 &&
        strcmp(getenv("SOL_BENCHMARK_DURATION_SECONDS") ?: "", benchmark_duration_at_load) == 0;
}

static void enqueue(const char *event) {
    if (event_count < (int)(sizeof(events) / sizeof(events[0]))) {
        events[event_count++] = event;
    }
}

static void write_benchmark(void) {
    if (report_written) {
        return;
    }
    report_written = 1;
    const char *path = getenv("SOL_BENCHMARK_OUTPUT");
    if (path == NULL || path[0] == '\0') {
        return;
    }
    FILE *file = fopen(path, "w");
    if (file == NULL) {
        return;
    }
    fputs(
        "{\"schemaVersion\":1,\"label\":\"private fixture\","
        "\"backend\":\"SolMetal\",\"rendererName\":\"Fixture GPU\","
        "\"completed\":true,\"configuredWarmupSeconds\":0,"
        "\"configuredDurationSeconds\":5,\"measuredSeconds\":5.01,"
        "\"presentedFrames\":301,\"presentedFramesPerSecond\":60.0,"
        "\"sourceFramesPerSecond\":{\"samples\":4,\"mean\":60.0,\"median\":60.0,\"p95\":60.0,\"p99\":60.0,\"minimum\":60.0,\"maximum\":60.0},"
        "\"presentFrameTimeMilliseconds\":{\"samples\":300,\"mean\":16.67,\"median\":16.67,\"p95\":17.0,\"p99\":18.0,\"minimum\":16.0,\"maximum\":19.0},"
        "\"fifoPercent\":{\"samples\":4,\"mean\":50.0,\"median\":50.0,\"p95\":51.0,\"p99\":52.0,\"minimum\":49.0,\"maximum\":52.0},"
        "\"processCpuPercent\":{\"samples\":4,\"mean\":80.0,\"median\":80.0,\"p95\":82.0,\"p99\":83.0,\"minimum\":78.0,\"maximum\":83.0},"
        "\"workingSetBytes\":{\"samples\":4,\"median\":500000000,\"p95\":510000000,\"minimum\":490000000,\"maximum\":520000000}}",
        file
    );
    fclose(file);
    chmod(path, 0600);
}

__attribute__((visibility("default")))
int32_t Start(
    void *cocoa_view,
    void *metal_layer,
    void *dlsm_callback,
    void *dlsm_context,
    const uint8_t *game_path,
    const uint8_t *data_directory,
    int32_t width,
    int32_t height
) {
    (void)dlsm_callback;
    (void)dlsm_context;
    if (cocoa_view == NULL || metal_layer == NULL || game_path == NULL ||
        data_directory == NULL || width < 64 || height < 64) {
        return -1;
    }
    if (!environment_ready_at_load) {
        return -2;
    }
    if (!environment_unchanged_since_load()) {
        return -3;
    }
    fprintf(stdout, "private game path: %s\n", (const char *)game_path);
    fprintf(stderr, "private data path: %s\n", (const char *)data_directory);
    fflush(stdout);
    fflush(stderr);
    event_count = 0;
    event_index = 0;
    report_written = 0;
    terminated = 0;
    enqueue("{\"protocol\":1,\"event\":\"host.ready\",\"path\":\"/private/should/not/escape\",\"message\":\"private message\"}");
    enqueue("{\"protocol\":1,\"event\":\"launch.progress\",\"loadStage\":\"starting-solmetal-gal\",\"message\":\"private path /tmp/secret\"}");
    enqueue("{\"protocol\":1,\"event\":\"launch.first-frame\",\"width\":1280,\"height\":720}");
    return 0;
}

__attribute__((visibility("default")))
int32_t Pump(void) {
    write_benchmark();
    return 1;
}

__attribute__((visibility("default")))
int32_t ReadEvent(uint8_t *buffer, int32_t capacity) {
    if (buffer == NULL || capacity <= 0 || event_index >= event_count) {
        return 0;
    }
    const char *event = events[event_index];
    int32_t length = (int32_t)strlen(event);
    if (length > capacity) {
        return -length;
    }
    memcpy(buffer, event, (size_t)length);
    event_index++;
    return length;
}

__attribute__((visibility("default")))
int32_t SendCommand(const uint8_t *json) {
    if (json == NULL || strstr((const char *)json, "\"stop\"") == NULL) {
        return -1;
    }
    enqueue("{\"protocol\":1,\"event\":\"session.state\",\"phase\":\"stopping\"}");
    return 0;
}

__attribute__((visibility("default")))
int32_t Shutdown(void) {
    if (!terminated) {
        terminated = 1;
        enqueue("{\"protocol\":1,\"event\":\"embedded.terminated\",\"exitCode\":0,\"message\":\"/private/termination/detail\"}");
    }
    return 0;
}
