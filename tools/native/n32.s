# tools/native/n32.s : the hottest imports of the Linux i386 builds as code that runs in the emulator
# (oracle/hle.lua: hle.native[32]), cdecl; tools/native/assemble.sh
.intel_syntax noprefix
.text
.globl f_memcpy, f_memmove, f_memset, f_memcmp, f_strlen, f_strcmp, f_tolower, f_toupper, f_end
f_memcpy: push edi
 push esi
 mov edi, [esp+12]
 mov esi, [esp+16]
 mov ecx, [esp+20]
 mov eax, edi
 rep movsb
 pop esi
 pop edi
 ret
f_memmove: push edi
 push esi
 mov edi, [esp+12]
 mov esi, [esp+16]
 mov ecx, [esp+20]
 mov eax, edi
 cmp edi, esi
 jbe 1f
 lea edx, [esi+ecx]
 cmp edi, edx
 jae 1f
 lea esi, [esi+ecx-1]
 lea edi, [edi+ecx-1]
 std
 rep movsb
 cld
 pop esi
 pop edi
 ret
1: rep movsb
 pop esi
 pop edi
 ret
f_memset: push edi
 mov edi, [esp+8]
 mov eax, [esp+12]
 mov ecx, [esp+16]
 mov edx, edi
 rep stosb
 mov eax, edx
 pop edi
 ret
f_memcmp: push esi
 push edi
 mov esi, [esp+12]
 mov edi, [esp+16]
 mov ecx, [esp+20]
 xor eax, eax
 test ecx, ecx
 jz 2f
1: movzx eax, byte ptr [esi]
 movzx edx, byte ptr [edi]
 sub eax, edx
 jnz 2f
 inc esi
 inc edi
 dec ecx
 jnz 1b
2: pop edi
 pop esi
 ret
f_strlen: mov edx, [esp+4]
 mov eax, edx
1: cmp byte ptr [eax], 0
 je 2f
 inc eax
 jmp 1b
2: sub eax, edx
 ret
f_strcmp: push esi
 mov edx, [esp+8]
 mov esi, [esp+12]
1: movzx eax, byte ptr [edx]
 movzx ecx, byte ptr [esi]
 sub eax, ecx
 jnz 2f
 test ecx, ecx
 jz 2f
 inc edx
 inc esi
 jmp 1b
2: pop esi
 ret
f_tolower: mov eax, [esp+4]
 lea ecx, [eax-65]
 cmp ecx, 25
 ja 1f
 add eax, 32
 ret
1: lea ecx, [eax+128]
 cmp ecx, 126
 ja 2f
 add eax, 256
2: ret
f_toupper: mov eax, [esp+4]
 lea ecx, [eax-97]
 cmp ecx, 25
 ja 1f
 sub eax, 32
 ret
1: lea ecx, [eax+128]
 cmp ecx, 126
 ja 2f
 add eax, 256
2: ret
f_end:
