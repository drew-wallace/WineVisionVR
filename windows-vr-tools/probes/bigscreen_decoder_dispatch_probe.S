.text
.globl run_decoder_dispatch
.def run_decoder_dispatch; .scl 2; .type 32; .endef
run_decoder_dispatch:
  pushq %rbx
  pushq %rbp
  pushq %rsi
  pushq %rdi
  pushq %r12
  pushq %r13
  pushq %r14
  pushq %r15
  subq $104, %rsp
  movq %rdx, 48(%rsp)
  callq *%rcx
  addq $104, %rsp
  popq %r15
  popq %r14
  popq %r13
  popq %r12
  popq %rdi
  popq %rsi
  popq %rbp
  popq %rbx
  retq
