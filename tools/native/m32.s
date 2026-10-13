# tools/native/m32.s : the libm functions of the Linux i386 builds that run in the emulator
# (oracle/hle.lua: hle.native[32], after n32.s), x87 with the rounding mode set; tools/native/assemble.sh
.intel_syntax noprefix
.text
.globl f_ceilf, f_ceil, f_floorf, f_floor, f_sqrtf, f_sqrt, f_end
f_ceilf: fld dword ptr [esp+4]
 mov ax, 0x0800
 jmp 1f
f_ceil: fld qword ptr [esp+4]
 mov ax, 0x0800
 jmp 1f
f_floorf: fld dword ptr [esp+4]
 mov ax, 0x0400
 jmp 1f
f_floor: fld qword ptr [esp+4]
 mov ax, 0x0400
1: sub esp, 8
 fnstcw [esp]
 mov dx, [esp]
 and dx, 0xf3ff
 or dx, ax
 mov [esp+2], dx
 fldcw [esp+2]
 frndint
 fldcw [esp]
 add esp, 8
 ret
f_sqrtf: fld dword ptr [esp+4]
 fsqrt
 ret
f_sqrt: fld qword ptr [esp+4]
 fsqrt
 ret
f_end:
