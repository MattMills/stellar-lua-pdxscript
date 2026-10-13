# tools/native/n64.s : the hottest imports of the Linux x86-64 builds as code that runs in the emulator
# (oracle/hle.lua: hle.native[64]), System V calling convention; tools/native/assemble.sh
.intel_syntax noprefix
.text
.globl f_memcpy, f_memmove, f_memset, f_memcmp, f_strlen, f_strcmp, f_tolower, f_toupper, f_end
f_memcpy: mov rax, rdi
 mov rcx, rdx
 rep movsb
 ret
f_memmove: mov rax, rdi
 mov rcx, rdx
 cmp rdi, rsi
 jbe 1f
 lea r8, [rsi+rdx]
 cmp rdi, r8
 jae 1f
 lea rsi, [rsi+rdx-1]
 lea rdi, [rdi+rdx-1]
 std
 rep movsb
 cld
 ret
1: rep movsb
 ret
f_memset: mov r8, rdi
 mov eax, esi
 mov rcx, rdx
 rep stosb
 mov rax, r8
 ret
f_memcmp: xor eax, eax
 test rdx, rdx
 jz 2f
1: movzx eax, byte ptr [rdi]
 movzx ecx, byte ptr [rsi]
 sub eax, ecx
 jnz 2f
 inc rdi
 inc rsi
 dec rdx
 jnz 1b
2: ret
f_strlen: mov rax, rdi
1: cmp byte ptr [rax], 0
 je 2f
 inc rax
 jmp 1b
2: sub rax, rdi
 ret
f_strcmp: movzx eax, byte ptr [rdi]
 movzx ecx, byte ptr [rsi]
 sub eax, ecx
 jnz 2f
 test ecx, ecx
 jz 2f
 inc rdi
 inc rsi
 jmp f_strcmp
2: ret
f_tolower: mov eax, edi
 lea ecx, [rdi-65]
 cmp ecx, 25
 ja 1f
 add eax, 32
 ret
1: lea ecx, [rdi+128]
 cmp ecx, 126
 ja 2f
 add eax, 256
2: ret
f_toupper: mov eax, edi
 lea ecx, [rdi-97]
 cmp ecx, 25
 ja 1f
 sub eax, 32
 ret
1: lea ecx, [rdi+128]
 cmp ecx, 126
 ja 2f
 add eax, 256
2: ret
f_end:
