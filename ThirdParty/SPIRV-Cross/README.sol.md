# SPIRV-Cross in SolMetal

This directory is a pinned source subset of KhronosGroup/SPIRV-Cross. SolMetal
uses it to translate SPIR-V shader modules into Metal Shading Language before
Apple's Metal compiler creates a function.

The copied files are unmodified upstream sources. `REVISION` records the exact
upstream commit. `LICENSE` contains the Apache License 2.0 text distributed by
the upstream project.

To update this dependency, replace the core, GLSL, and MSL source sets listed
in upstream `CMakeLists.txt`, update `REVISION`, then run
`script/test_sol_metal.sh` including its sanitizer and lifecycle gates.
