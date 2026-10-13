# tools/native/m64.s : the libm functions of the Linux x86-64 builds that run in the emulator
# (oracle/hle.lua: hle.native[64], after n64.s), SSE4.1; tools/native/assemble.sh
.intel_syntax noprefix
.text
.globl f_ceilf, f_ceil, f_floorf, f_floor, f_sqrtf, f_sqrt, f_end
f_ceilf: roundss xmm0, xmm0, 0x0a
 ret
f_ceil: roundsd xmm0, xmm0, 0x0a
 ret
f_floorf: roundss xmm0, xmm0, 0x09
 ret
f_floor: roundsd xmm0, xmm0, 0x09
 ret
f_sqrtf: sqrtss xmm0, xmm0
 ret
f_sqrt: sqrtsd xmm0, xmm0
 ret
f_end:
