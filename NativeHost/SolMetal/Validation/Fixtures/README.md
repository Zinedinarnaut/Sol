# SolMetal shader fixtures

These small GLSL programs are deterministic validation inputs for SolMetal's
SPIR-V translation boundary. Their checked-in `.spv` files let normal builds
and tests run without installing a shader compiler.

`CompileFixture.c` regenerates one binary at a time with shaderc:

```sh
cc -std=c17 -I/path/to/shaderc/include \
  CompileFixture.c -L/path/to/shaderc/lib -lshaderc_shared \
  -o compile-fixture

./compile-fixture SolMetalAdd.comp SolMetalAdd.spv
```

Regenerate a binary only when its adjacent GLSL source intentionally changes,
then run `./script/test_sol_metal.sh`. The runtime consumes the checked-in
SPIR-V; it does not load shaderc or execute this helper.
