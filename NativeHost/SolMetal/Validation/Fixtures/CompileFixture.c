#include <shaderc/shaderc.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *read_file(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        return NULL;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return NULL;
    }
    const long size = ftell(file);
    if (size <= 0 || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return NULL;
    }
    char *bytes = malloc((size_t)size + 1);
    if (bytes == NULL || fread(bytes, 1, (size_t)size, file) != (size_t)size) {
        free(bytes);
        fclose(file);
        return NULL;
    }
    fclose(file);
    bytes[size] = '\0';
    *length = (size_t)size;
    return bytes;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s input.comp output.spv\n", argv[0]);
        return 2;
    }

    size_t source_length = 0;
    char *source = read_file(argv[1], &source_length);
    shaderc_compiler_t compiler = shaderc_compiler_initialize();
    if (source == NULL || compiler == NULL) {
        free(source);
        shaderc_compiler_release(compiler);
        return 3;
    }

    shaderc_shader_kind shader_kind = shaderc_glsl_infer_from_source;
    const char *extension = strrchr(argv[1], '.');
    if (extension != NULL && strcmp(extension, ".comp") == 0) {
        shader_kind = shaderc_compute_shader;
    } else if (extension != NULL && strcmp(extension, ".vert") == 0) {
        shader_kind = shaderc_vertex_shader;
    } else if (extension != NULL && strcmp(extension, ".frag") == 0) {
        shader_kind = shaderc_fragment_shader;
    }

    shaderc_compilation_result_t result = shaderc_compile_into_spv(
        compiler,
        source,
        source_length,
        shader_kind,
        argv[1],
        "main",
        NULL);
    free(source);
    shaderc_compiler_release(compiler);
    if (result == NULL ||
        shaderc_result_get_compilation_status(result) !=
            shaderc_compilation_status_success) {
        fprintf(stderr, "%s\n", result == NULL
            ? "shaderc returned no result"
            : shaderc_result_get_error_message(result));
        shaderc_result_release(result);
        return 4;
    }

    FILE *output = fopen(argv[2], "wb");
    const size_t length = shaderc_result_get_length(result);
    const char *bytes = shaderc_result_get_bytes(result);
    const int status = output != NULL && fwrite(bytes, 1, length, output) == length
        ? 0
        : 5;
    if (output != NULL) {
        fclose(output);
    }
    shaderc_result_release(result);
    return status;
}
