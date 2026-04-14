# Evaluation
## Part C
Below is the results of my `lscpu` command.
```
[aem515@general-dy-general-cr-8 ~]$ lscpu
Architecture:                x86_64
  CPU op-mode(s):            32-bit, 64-bit
  Address sizes:             46 bits physical, 48 bits virtual
  Byte Order:                Little Endian
CPU(s):                      48
  On-line CPU(s) list:       0-47
Vendor ID:                   GenuineIntel
  Model name:                Intel(R) Xeon(R) Platinum 8275CL CPU @ 3.00GHz
    CPU family:              6
    Model:                   85
    Thread(s) per core:      2
    Core(s) per socket:      24
    Socket(s):               1
    Stepping:                7
    BogoMIPS:                5999.99
    Flags:                   fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush mmx fxsr sse sse2 ss ht syscall nx 
                             pdpe1gb rdtscp lm constant_tsc arch_perfmon rep_good nopl xtopology nonstop_tsc cpuid aperfmperf tsc_known_freq pni
                              pclmulqdq monitor ssse3 fma cx16 pcid sse4_1 sse4_2 x2apic movbe popcnt tsc_deadline_timer aes xsave avx f16c rdra
                             nd hypervisor lahf_lm abm 3dnowprefetch cpuid_fault pti fsgsbase tsc_adjust bmi1 avx2 smep bmi2 erms invpcid mpx av
                             x512f avx512dq rdseed adx smap clflushopt clwb avx512cd avx512bw avx512vl xsaveopt xsavec xgetbv1 xsaves ida arat p
                             ku ospke avx512_vnni
Virtualization features:     
  Hypervisor vendor:         KVM
  Virtualization type:       full
Caches (sum of all):         
  L1d:                       768 KiB (24 instances)
  L1i:                       768 KiB (24 instances)
  L2:                        24 MiB (24 instances)
  L3:                        35.8 MiB (1 instance)
NUMA:                        
  NUMA node(s):              1
  NUMA node0 CPU(s):         0-47
Vulnerabilities:             
  Gather data sampling:      Unknown: Dependent on hypervisor status
  Indirect target selection: Mitigation; Aligned branch/return thunks
  Itlb multihit:             KVM: Mitigation: VMX unsupported
  L1tf:                      Mitigation; PTE Inversion
  Mds:                       Vulnerable: Clear CPU buffers attempted, no microcode; SMT Host state unknown
  Meltdown:                  Mitigation; PTI
  Mmio stale data:           Vulnerable: Clear CPU buffers attempted, no microcode; SMT Host state unknown
  Reg file data sampling:    Not affected
  Retbleed:                  Vulnerable
  Spec rstack overflow:      Not affected
  Spec store bypass:         Vulnerable
  Spectre v1:                Mitigation; usercopy/swapgs barriers and __user pointer sanitization
  Spectre v2:                Mitigation; Retpolines; STIBP disabled; RSB filling; PBRSB-eIBRS Not affected; BHI Retpoline
  Srbds:                     Not affected
  Tsa:                       Not affected
  Tsx async abort:           Not affected
  Vmscape:                   Not affected
[aem515@general-dy-general-cr-8 ~]$ 
```
My machine is most likely using a modern Intel Cascade Lake conditional-branch predictor that is much more sophisticated than either a simple bimodal predictor or the HHRT+PT two-level predictor. The closest published description is a TAGE-like hybrid predictor with a global path-history register, multiple tagged pattern-history tables, and a bimodal-like base predictor. Intel does not officially publish the exact predictor implementation, so this is an evidence-based inference, not a vendor-confirmed fact.
