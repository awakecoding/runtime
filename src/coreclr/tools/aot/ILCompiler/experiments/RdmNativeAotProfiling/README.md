# RDM NativeAOT compiler profiling experiment

This experiment profiles the NativeAOT compiler while publishing Remote Desktop Manager (RDM).
It keeps RDM source untouched, redirects build outputs, and uses a compiler built from the same
runtime servicing tag as RDM's NativeAOT packs.

The scripts require PowerShell 7 and the normal dotnet/runtime Windows build prerequisites.

## Executive summary

The authoritative workload is RDM's true-AOT `RdmNativeAotFast=true` profile targeting
`net10.0-windows10.0.19041` and `win-x64`. It disables optimized code generation and native
debug data, but it retains whole-program dependency analysis, reflection metadata, native
interop generation, object emission, and native linking.

The dominant costs are not method code generation or the native linker:

| Cost | Wall time | Share of measured ILC |
| --- | ---: | ---: |
| Dependency graph and code generation | 454.398 s | 65.89% |
| Object emission | 234.936 s | 34.07% |
| Method-codegen batches (overlaps graph row) | 34.843 s | 5.05% |
| Metadata computation (overlaps graph/object work) | 24.255 s | 3.52% |
| Native link | 30.7-32.4 s | about 3% of a fresh publish |

The graph contains 30,666,594 marked nodes. The resulting 3,744,336,196-byte COFF BigObj
contains 3,526,007 sections and 18,258,125 symbols. ILC allocated 123.80 GB of managed memory,
performed 178/83/36 gen0/gen1/gen2 collections, and peaked at 35.16 GB working set. Average
CPU use was only 2.44 of 19 logical processors.

Method code generation is already burst-parallel. An intrusive per-method profile measured
2,532,964 compilation invocations over 86 batches, with 16.89 average active workers while a
batch was running and a maximum of 19. In the low-overhead run, 419.556 seconds, or 92.33% of
graph/codegen wall time, was outside the parallel method batches. Increasing existing method
parallelism is therefore unlikely to materially improve total build time.

Three optimization waves tested 15 full-RDM hypotheses. The final accepted set reduced
managed allocation by 2.634 GiB (-2.31%) against its bracket midpoint, graph time by
1.865 seconds, and mark-stack time by 3.230 seconds. Total wall fell 4.131 seconds (-0.68%),
which is below the shared-machine variance floor and is not presented as an expected build
speedup. The strongest new standalone result was concrete dependency-list iteration:
170.0 million entries avoided interface enumeration, cutting 1.35-1.39 GiB of allocation and
about 7.3 seconds from graph/mark time.

## Exact baseline

| Item | Value |
| --- | --- |
| Main runtime checkout | `c210d82dbc1ab432b9369604a1caef9a0ab763d2` |
| Authoritative runtime source | tag `v10.0.11`, commit `79d0c463f1b55624c874a11585f7e47731e8d675` |
| RDM source | `e58d2275d44deaec64749d565bad4610800b4b82`, with its existing dirty experiment changes |
| SDK | `10.0.303` |
| OS/CPU | Windows x64, Intel Core Ultra 9 285HX, 19 logical processors |
| Memory | 63.5 GB physical |
| Uninstrumented `ilc.exe` SHA-256 | `D14A7FC888E010CA8B9E5EEA6E8FE1BF13171494393D794B9C9BA29301F313E3` |
| Uninstrumented `ilc.dll` SHA-256 | `4C8F52325269932B9BCEE42C2C54EA98C2E43B2C9DA69F2A69863DACF9DF64EB` |
| Phase-profile `ilc.dll` SHA-256 | `59BD8E06D5C92D3121860C94432C55B60FC70F0E6F17716A9705BDB2BD6F3A68` |

The executable host hash does not change when managed compiler code changes, so identify a
profiled build by both `ilc.exe` and `ilc.dll`.

The matching toolchain build command was:

```powershell
.\build.cmd clr.aot+libs -rc Release -lc Release
```

The first nested source path exceeded MSVC path limits. Building through `subst N:` succeeded
in 7 minutes 32.6 seconds. `Build-LocalToolchain.ps1` automates the short-path build.

The exact live-build overrides were:

```text
IlcToolsPath=<runtime>\artifacts\bin\coreclr\windows.x64.Release\ilc\
IlcSdkPath=<runtime>\artifacts\bin\coreclr\windows.x64.Release\aotsdk\
IlcFrameworkPath=<runtime>\artifacts\bin\microsoft.netcore.app.runtime.win-x64\
    Release\runtimes\win-x64\lib\net10.0\
IlcFrameworkNativePath=<runtime>\artifacts\bin\microsoft.netcore.app.runtime.win-x64\
    Release\runtimes\win-x64\native\
```

The locally built `Microsoft.DotNet.ILCompiler.SingleEntry.targets`,
`Microsoft.NETCore.Native.targets`, and `Microsoft.NETCore.Native.Windows.targets` were
byte-identical to the restored 10.0.11 package targets.

## Validation

A `net10.0` console sample published using SDK 10.0.303 and the four local overrides. Its
binlog proves the local ILC path:

| Step | Result |
| --- | ---: |
| Complete sample publish | 8.818 s |
| ILC task | 2.142 s |
| Native link | 0.264 s |
| Executable | 1,107,968 bytes |
| Execution | printed `Hello from net10`, exit code 0 |

The RDM publish produced:

| Artifact | Result |
| --- | ---: |
| Native object | 3,744,336,196 bytes |
| Native executable | 1,038,626,304 bytes |
| Complete publish | 1,454,594,021 bytes, 558 files |
| Object SHA-256 in phase and method profiles | `D50C6FE7334C57FE9E03B1D654C056FB0A6A5FA500ED6D64719F35AA0BF6EAAC` |

The initial isolated output path made `link.rsp` 265 characters long, and MSVC returned
`LNK1104`. Relinking the preserved object through a short drive mapping succeeded twice in
30.7-32.4 seconds with about 10.2 GB peak working set. The output wrapper now uses an
eight-character project hash, but callers should still choose a short run root.

## End-to-end timing

The first fresh run reached ILC 124.4 seconds after publish started. Its ILC task took
784.825 seconds. Replacing the failed long-path link with the measured successful link and
then completing `publish --no-build` gives an effective 951.9-second (15 minute 51.9 second)
publish, or 958.1 seconds including the separate restore:

| Stage | Wall time |
| --- | ---: |
| Restore | 6.2 s |
| Managed project preparation | 124.4 s |
| ILC control run 1 | 784.825 s |
| MSVC link | 32.4 s |
| Copy/final publish | 10.25 s |

An unchanged second publish had a 694.348-second ILC task and an effective total near
784.0 seconds after substituting the successful link. The two uninstrumented ILC controls
differed by 13.0%, so wall comparisons must use a matched run and not a single baseline.

## Retained artifacts

The measured artifacts for this session are under:

```text
<workspace>\artifacts\nativeaot-profile\
```

Key paths are:

| Evidence | Relative path |
| --- | --- |
| Outer MSBuild binlog | `rdm-runs\baseline-1\publish.binlog` |
| Local-ILC RDM publish | `rdm-runs\baseline-1\publish\` |
| Low-overhead phase CSV | `rdm-runs\phase-only-final\ilc-profile.csv` |
| Low-overhead process samples | `rdm-runs\phase-only-final\ilc-samples.csv` |
| Fine-grained method CSV | `rdm-runs\instrumented-direct\ilc-profile.csv` |
| Fine-grained process samples | `rdm-runs\instrumented-direct\ilc-samples.csv` |
| Top method/assembly analysis | `rdm-runs\instrumented-direct\analysis.json` |
| RDM ILC response | `rdm-runs\baseline-1\obj\...\native\RemoteDesktopManager.ilc.rsp` |
| Matching v10.0.11 source/build | `runtime-10.0.11-src\` |

## Low-overhead ILC phase profile

The final phase-only run took 692.809 seconds versus the closest uninstrumented control at
694.348 seconds, a -0.22% difference within normal run variance. It generated the same object
hash and did not collect per-method data.

| Phase | Wall time | Share |
| --- | ---: | ---: |
| Process startup and command-line parsing | 3.218 s | 0.46% of process |
| Input and type-system setup | 0.110 s | 0.02% |
| Compilation setup | 0.114 s | 0.02% |
| Dependency graph and code generation | 454.398 s | 65.89% |
| File layout | 0.001 s | less than 0.01% |
| Object emission | 234.936 s | 34.07% |
| Finalization | 0.017 s | less than 0.01% |

`RdmNativeAotFast` sets `Optimize=false`. In .NET 10 ILC, the separate scanner only runs for
optimized non-multifile builds unless explicitly requested. The response contains
`--scanreflection`, but the scanner phase is zero; reflection/dataflow analysis occurs while
the dependency graph is expanded.

The first large object write occurred at 643.7 seconds. Object emission began near
457.8 seconds, so about 185.8 of its 234.9 seconds elapsed before sustained disk writes.
The main object-writer opportunity is therefore node materialization, section/symbol
construction, and relocation/layout processing, not merely faster storage.

## Graph and root attribution

The response file has one executable input and 684 references:

| Reference source | Count |
| --- | ---: |
| NuGet packages | 467 |
| Local .NET runtime framework | 175 |
| RDM-built assemblies | 42 |

There are no `--root`, `--conditionalroot`, `--trim`, default-rooting, or all-reflection
options. The entry point is the implicit root. Static application registration and
serializer code reachable from that entry point expand the closure.

Concrete graph multipliers include:

* Three compiled `GeneratedViewLocatorRegistry` implementations contain 1,215 registration
  calls: 1,124 in `Devolutions.AvaloniaUI`, 89 in DataSources, and 2 in Options.
* Managed preparation generated 36.7 MB and 537,220 lines of unique generated C# source.
  The largest files are the 13.6 MB/195,830-line Core XML serializer and two
  11.4 MB/168,985-line Business serializer variants.
* The fine profile's top 300 type rows contain 46,701 compiled-Avalonia-XAML invocations,
  36,889 JSON-context/metadata invocations, 6,463 XML serializer/loader invocations, and
  32,937 generic collection machinery invocations. These are partial counts, not graph-wide
  totals.
* ILC emitted 52 resilient throw-only compilations: 26 invalid IL/metadata, 13 missing
  assemblies, 7 missing methods, and 6 missing types. Sixteen came from
  `Interop.FCCOMINTLib`, ten from RDM Core, and six were compiler-generated. These are
  compatibility defects or dead capabilities that still consume graph work.

Generating a 30-million-node DGML/EventSource trace solely to classify every dependency node
would materially distort this workload and create a very large artifact, so it was
deliberately avoided. COFF cardinality and the compiler's marked-node/method counters provide
the low-overhead structural evidence.

## Fine-grained code generation

Per-method timing is opt-in because it is intrusive. Against the phase-only run it added
55.8% wall time, 18.3% CPU time, and 5.0% peak working set while producing byte-identical
output. Use it for ranking only, not phase durations.

| Assembly | Method invocation count | Method wall-sum | Share of method wall-sum |
| --- | ---: | ---: | ---: |
| `System.Private.CoreLib` | 949,806 | 228.403 s | 27.28% |
| `RemoteDesktopManager.Core` | 130,564 | 137.774 s | 16.46% |
| Compiler-generated | 289,320 | 47.783 s | 5.71% |
| `System.Text.Json` | 152,677 | 37.727 s | 4.51% |
| `Devolutions.AvaloniaUI` | 60,794 | 34.362 s | 4.10% |
| `Avalonia.Base` | 121,707 | 26.759 s | 3.20% |
| `Microsoft.Graph` | 49,749 | 21.854 s | 2.61% |
| `System.Linq` | 43,720 | 15.646 s | 1.87% |
| `GitHub.Copilot.SDK` | 41,466 | 14.794 s | 1.77% |
| `DocumentFormat.OpenXml` | 56,210 | 12.549 s | 1.50% |

The slowest individual methods included two `System.Reactive.Subscribe<T>` instantiations
at 1.29-1.31 seconds, `VariableManager.RegisterVariables` at 0.761 seconds, OpenTK entry-point
initialization at 0.730 seconds, and an RDM password-generator helper at 0.672 seconds.
Individual method work is too small and too parallel to explain the total wall time.

## Ranked optimization opportunities

### Low-effort RDM graph reductions

1. **Partition the generated ViewLocator closure by NativeAOT capability.** The 1,215 static
   registrations make every constructor and transitive dependency reachable. Generate
   per-feature registries and include only capabilities present in the NativeAOT product.
   A 10% whole-graph reduction has a rough upper bound near 69 seconds on this profile,
   assuming graph and object costs scale approximately linearly.
2. **Reduce generated XML serializer breadth and duplicate variants.** The generated sources
   alone total 36.7 MB/537k lines. Generate only schemas used by the NativeAOT profile and
   avoid building equivalent RID/non-RID variants when one result can be reused.
3. **Exclude optional SDK and feature families before ILC.** `Microsoft.Graph`, OpenXML,
   Copilot/AI JSON contexts, OpenAI, Google GenAI, and related generic metadata are visible
   among the largest codegen groups. Prefer a capability-specific process or assembly
   boundary when the main NativeAOT executable does not need them.
4. **Turn resilient throw-only results into graph exclusions or explicit compatibility
   failures.** Missing WPF assemblies, stale Avalonia/AI APIs, COM metadata, and generated
   marshalling failures should not silently remain in a shipping closure.

Do not disable reflection scanning merely for speed: doing so stops surfacing reflection and
trim incompatibilities and can remove metadata required at runtime. Likewise,
`IlcResilient=false` is useful in a compatibility CI lane because it converts the 52
throw-only bodies into failures, but it is not a compatibility-preserving speed switch.
Disabling stack-trace data or debugger support reduces diagnostics and must be evaluated as a
product tradeoff.

### Medium compiler and build work

1. **Reduce dependency-graph allocation and serial processing.** This is the largest measured
   ceiling at 454.4 seconds. Method batches use only 34.8 seconds; 419.6 seconds of graph wall
   is elsewhere. Prioritize fewer transient nodes, cheaper interning/hash structures,
   global duplicate suppression, and parallel deferred-dependency processing. A 25%
   improvement to this phase would save about 113.6 seconds.
2. **Stream or parallelize object materialization.** Object emission is 234.9 seconds and
   creates 3.526 million sections and 18.258 million symbols. A 25% improvement would save
   about 58.7 seconds. Build section contents and relocations in partitions, then perform a
   deterministic merge, rather than retaining the entire object model before writing.
3. **Lower peak live data and GC pressure.** ILC allocated 123.8 GB and performed 36 gen2
   collections. Compact node/edge/relocation representations and earlier release of graph
   state should improve both graph and object phases and reduce the 35 GB memory requirement.
4. **Keep MSBuild preparation incremental.** Managed preparation costs roughly two minutes on
   a clean output. XML generation, Avalonia XAML, and C# compilation are secondary to ILC but
   remain worthwhile once the compiler bottlenecks improve.

The native linker is not a priority: it completes in about 31 seconds with CPU time close to
wall time. Existing method-codegen parallelism is also not the bottleneck; raising ILC
parallelism would increase memory pressure without addressing the serial graph/object work.

### Major runtime architecture work

1. **Add a correctness-preserving cross-run NativeAOT cache.** Any managed input change
   invalidates one giant object, while an unchanged MSBuild publish can finish in seconds.
   Cache method/object fragments by IL, generic context, compiler settings, and dependency
   facts, then deterministically merge them.
2. **Support compositional compilation with whole-program metadata and generic correctness.**
   Current multifile mode is non-shipping, forfeits optimizations, and has unresolved
   reflection/generic-virtual-method limitations. A supported partition model could reuse
   stable framework and optional-module partitions.
3. **Make dependency analysis and object writing explicitly parallel algorithms.** Current
   concurrency is concentrated in short method batches; the phases with the largest ceilings
   remain predominantly serial.

PGO is a runtime-performance tool, not a build-time remedy. It can increase compilation work
and does not address the measured graph and object-writer costs.

## Wave 1 optimization experiments

Wave 1 tested five independently gated implementation hypotheses against the exact retained
RDM response file (SHA-256
`997874CB4139F822AA2C659727E9BA93960B7F9872970A8D4322DC007FC9EDF9`).
All controls and experiments used one compiler build and changed only
`DOTNET_ILC_EXPERIMENTS`.

The shared machine produced valid control times from 605.450 to 818.591 seconds despite an
idle-start guard, so total wall time alone is not a reliable comparison. Results use:

* interleaved controls;
* the midpoint of controls bracketing a variant when both were in the same regime;
* targeted subphase direction across repetitions;
* allocation, GC, and peak-memory measurements;
* object size/hash and COFF cardinality checks.

One null-interner run and one control were terminated and excluded when unrelated system
load left only 5.7-7.7 GB physical memory available. Raw valid and invalid runs are retained
under `artifacts\nativeaot-profile\experiments\full-rdm`.

| Hypothesis | Implementation | Full RDM result | Verdict |
| --- | --- | --- | --- |
| Filter final graph before sorting | Stable-partition non-object nodes and sort only `ObjectNode` instances | 13.455M of 30.667M nodes still required sorting. Sort rose 10.307 to 13.307 s; wall regressed 3.5%. | **Regression** |
| Null-interner fast path | Return immediately for `ObjectDataInterner.Null` | Target materialization was +2.0% in pair 1 and -2.2% in pair 2; allocation was neutral. | **Neutral** |
| Lazy per-section state | Lazy symbolic/COFF relocation lists, shared padding, inline first section buffer | Allocation fell 1.13-1.21 GiB in both runs. Pair 2 object emission fell 5.6%; pair 1 was nearly neutral. | **Win: memory and modest object time** |
| Eager object-writer preallocation | Pre-size 3.833M section and 18.400M symbol slots | Pair 1 object emission fell 8-12%; pair 2 regressed 22.6%. Allocation fell about 0.6 GiB but response to memory/cache regime was unstable. | **Neutral/unstable** |
| Hash-based COFF string reservation | HashSet deduplication plus one ordinal sort before suffix sorting | `coff-string-reserve` fell from 7.66-8.59 s to 4.63 s (40-46%). Output and allocation were unchanged. | **Win: targeted 3-4 s** |

The filtered-sort object was the only non-byte-identical output. It retained identical size
and cardinality and linked successfully into the same-size RDM executable. The layout change
comes from comparer-equal ordering boundaries. Every other experiment produced the same
3,744,336,196-byte object with SHA-256
`5B3E5823E9BE816DACD4D47311449E20F0F8233FC5A853439BC30F1F2A351B3D`.

### Wave 1 combined result

The accepted combination is:

```text
lazy-relocation-lists;compact-section-data;string-table-hashset
```

Its repeat run was compared with controls at 818.591 and 605.450 seconds. That 213-second
control swing makes the raw -9.7% midpoint result or +6.2% nearest-control result unsuitable
as an expected end-to-end gain. Targeted phases and resources are stable enough to establish
the mechanism:

| Metric | Control midpoint | Combined | Change |
| --- | ---: | ---: | ---: |
| Object emission | 202.10 s | 195.08 s | -3.47% |
| Node materialization | 114.97 s | 111.42 s | -3.08% |
| Relocation resolution | 25.72 s | 22.54 s | -12.37% |
| COFF string reservation | 11.66 s | 4.24 s | -63.63% |
| Object file write | 39.24 s | 38.10 s | -2.92% |
| Managed allocation | 115.55-115.77 GiB | 113.97 GiB | -1.58 to -1.80 GiB |
| Peak working set | 33.77-35.34 GiB | 33.75 GiB | neutral to -1.59 GiB |

COFF symbol writing regressed in this sample, offsetting part of the string-reservation
saving. Wave 1 therefore proves lower allocation and about seven seconds of object-phase
work, but not a repeatable whole-compiler wall reduction above environmental variance.

### Wave 1 screening replacements

Three additional gates were screened but did not consume a full RDM run:

* `deferred-phase-lists` replaced an integer-keyed dictionary with phase-indexed lists but
  showed no targeted benefit on the 204,906-node EntryModel graph.
* `conditional-remove` combined lookup/removal of satisfied conditional dependencies but
  showed no targeted benefit.
* `large-coff-buffer` used a 1 MB sequential file buffer but did not improve the 95 MB
  EntryModel object-write phase.

## Wave 2 optimization experiments

Wave 2 used the Wave 1 lessons to test narrower representations and hot loops rather than
larger eager reservations. The exact response remained unchanged. All fresh controls and
variants in this wave produced a 3,744,339,247-byte object with SHA-256
`A267FA3F2402258BAFC93EFDE72DAE04AB1050959788D6CCDB8B64BC477DFFD9`.
The fresh closure was 30,666,605 nodes, 3,526,010 sections, 18,258,144 symbol records, and
41,018,549 COFF relocation records.

This is 11 nodes, three sections, 19 symbols, and 3,051 bytes above the Wave 1 object. The
drift appeared after rebuilding the compiler with the additional gated implementations, but
was stable across every Wave 2 control and experiment, including controls after a subsequent
compiler rebuild. Its precise scheduling-sensitive source was not isolated. Wave 2 therefore
uses only controls from the same source generation and requires identity to the fresh object.

`Invoke-IlcProfile.ps1` now gates a run on consecutive free-memory and background-CPU
samples, and records start/end free memory, CPU load, current/max frequency indicators,
private bytes, paged bytes, and working set. Runs normally required three samples with at
least 25-27 GiB available and no more than 15% CPU load. No ACPI thermal-zone data was
available on this machine.

| Hypothesis | Structural evidence | Targeted full-RDM result | Verdict |
| --- | --- | --- | --- |
| Inline singleton conditional buckets | 5,724,010 buckets; 1,189,313 promoted to a multi-entry set | Allocation fell 0.68-0.76 GiB, but graph/mark did not beat controls and wall was 712.59 s | **Regression: reject** |
| Batch small COFF writes | 66,335,850 logical writes became 1,919 underlying writes; 1.872 GiB was copied through the buffer | File write was 36.39 s versus 48.02/33.41 s controls; the warm control was faster without the extra copy | **Neutral: reject** |
| Skip UTF-8 counting for clearly long names | Applied across 3,526,010 section and 18,258,144 symbol records | Symbol write was 24.10 s versus 20.51/21.37 s controls; allocation was unchanged | **Regression: reject** |
| Store COFF relocations as values | Replaced one heap record per 41,018,549 relocations with 12-byte values | Allocation fell 0.51-0.67 GiB. Conversion was 8.35 s versus 15.15/8.23 s controls, so timing did not repeat beyond the warm floor | **Win: memory; wall neutral** |
| Store COFF symbols as chunked values | 18,258,144 records occupied 279 chunks with only 26,400 unused slots | Allocation fell 0.50-0.73 GiB and peak private memory by up to 0.97 GiB, but symbol write rose to 35.72 s from 21.37/22.85 s | **Regression: reject** |

The compact-symbol prototype was corrected to use readonly writes and a ref-returning,
chunk-cached enumerator after the first full run exposed defensive-copy risk. Three
interleaved EntryModel pairs remained neutral to slower: median symbol write was 101.5 ms
with compact symbols versus 95.0 ms in controls. It was not given another expensive RDM run.
This is the key representation lesson: removing heap objects is insufficient when iteration
adds indirection or value-copy costs.

The initial Wave 2 screen also rejected a broad 1,024-entry `NodeCache` capacity hint and a
broad lock-free type-system table hint. The latter added about 290 MB on EntryModel. Compact
relocation and symbol representations replaced those candidates before full RDM testing.

### Wave 2 full-run matrix

The controls still moved from 619.11 to 676.18 seconds. Targeted phases, allocation, and
within-build byte identity remain the primary evidence.

| Run | Wall | Graph | Object | Allocation | Peak private |
| --- | ---: | ---: | ---: | ---: | ---: |
| Control A | 676.18 s | 436.29 s | 236.57 s | 115.45 GiB | 35.43 GiB |
| Conditional singleton bucket | 712.59 s | 443.74 s | 265.37 s | 114.77 GiB | 36.18 GiB |
| Batched COFF writes | 660.47 s | 447.16 s | 209.70 s | 115.57 GiB | 35.53 GiB |
| Control B | 666.90 s | 445.52 s | 217.35 s | 115.53 GiB | 35.64 GiB |
| Fast long-name classification | 651.90 s | 440.29 s | 207.79 s | 115.62 GiB | 36.29 GiB |
| Compact COFF relocations | 638.62 s | 431.55 s | 203.01 s | 115.02 GiB | 35.50 GiB |
| Control C | 619.11 s | 419.81 s | 195.60 s | 115.69 GiB | 36.25 GiB |
| Compact COFF symbols | 668.87 s | 441.60 s | 223.46 s | 114.96 GiB | 35.28 GiB |
| Control D | 636.60 s | 436.48 s | 196.48 s | 115.46 GiB | 35.41 GiB |

### Combined Wave 1 and Wave 2 result

The cumulative candidate added compact COFF relocations to the accepted Wave 1 set:

```text
compact-section-data;lazy-relocation-lists;string-table-hashset;compact-coff-relocations
```

It was bracketed by fresh controls E and F from the same corrected compiler build. The
candidate began at 76% reported maximum frequency versus 88-89% for the controls, which
explains much of its slower graph phase. Its total of 652.82 seconds was 0.8% above the
647.60-second control midpoint and is neutral.

| Metric | Control E/F midpoint | Combined | Change |
| --- | ---: | ---: | ---: |
| Object emission | 218.55 s | 206.17 s | -12.38 s (-5.67%) |
| Node materialization | 124.88 s | 115.05 s | -9.83 s (-7.87%) |
| Relocation resolution | 21.34 s | 21.11 s | -0.23 s (-1.08%) |
| Relocation conversion | 13.64 s | 5.81 s | -7.83 s (-57.40%) |
| COFF string reservation | 14.69 s | 4.37 s | -10.32 s (-70.25%) |
| Object file write | 46.73 s | 53.62 s | +6.89 s (+14.75%) |
| Managed allocation | 115.48-115.78 GiB | 113.99 GiB | -1.49 to -1.79 GiB |
| Peak private memory | 35.65 GiB | 34.37 GiB | -1.28 GiB |

The allocation and targeted object-work reductions are compatible and repeat the mechanisms
seen independently. They are insufficient to claim an end-to-end wall win because file-write
cache effects moved oppositely and the serial graph still dominates. Raw Wave 2 evidence is
under `artifacts\nativeaot-profile\experiments\wave2-full-rdm`; the compact table is
`artifacts\nativeaot-profile\experiments\wave2-full-rdm-summary.csv`.

The cumulative object linked successfully in 37.57 seconds to a 1,038,627,840-byte RDM
executable with SHA-256
`03A2410172683BF5072245C926C256E552931BF7F24D6280EAE864EA6042D162`.
The reconstructed v10.0.11 compiler build succeeded, and
`ILCompiler.Compiler.Tests` passed 21 of 21 tests.

## Wave 3 optimization experiments

Wave 3 started from the cumulative Wave 1+2 base:

```text
compact-section-data;lazy-relocation-lists;string-table-hashset;compact-coff-relocations
```

Six initial hypotheses and replacements were screened in 22 interleaved EntryModel runs.
Every output was byte-identical. Screening rejected incremental dynamic-dependency scanning
(only 134 provider visits), reference-equality conditional keys, one-lookup mangled-name
caching, stopping object traversal at the sorted non-object tail, flat and inline compact
symbolic-relocation representations, and a segmented mark stack. The latter representations
confirmed that per-section overcapacity and indirection can cost more than the heap objects
they remove.

The final five candidates all received full RDM runs. Wave 3 controls and variants produced
the same 3,744,339,247-byte object with SHA-256
`C71AA7E9BAC37D9F2A2B2E2D75C695947D70CBD4EE39464C3623C4C9A8B75668`.
The node, section, symbol, relocation, and output-byte counts were identical.

| Hypothesis | Full-scale cardinality | Measured result | Verdict |
| --- | ---: | --- | --- |
| Concrete dependency-list iteration | 28.536M static lists/96.861M entries; 6.715M conditional lists/73.188M entries | Graph and mark each fell about 7.3 s versus A/B midpoint; allocation fell 1.35-1.39 GiB | **Win: graph time and memory** |
| Reference-backed singleton conditional buckets | 5.724M buckets; 1.189M promoted | Allocation fell 0.66-0.71 GiB in both runs. Frequency-matched confirmation cut graph 6.76 s and mark 9.12 s; first run was frequency-confounded | **Win: memory; provisional graph time** |
| Planned symbolic-relocation capacities | 46.784M relocation candidates; 41.019M emitted records; planning pass 0.36 s | Allocation fell 0.47-0.53 GiB; object time was -1.55 s versus B/C midpoint but resolution was +1.15 s | **Win: memory; timing neutral** |
| Exact compact COFF capacities | 41.019M records | Allocation fell 0.95-1.01 GiB, but peak private memory rose 1.45-1.91 GiB in its bracket and 1.61 GiB in confirmation; targeted timing did not repeat | **Regression: reject on peak memory** |
| Chunked relocation-block values | 7.777M records in 119 chunks | Allocation fell 0.20-0.23 GiB; object/materialization timing did not beat the C/D midpoint | **Neutral: exclude** |

Symbolic capacities are per-section upper bounds computed from actual relocation arrays;
locally resolved candidates account for the difference between the 46.784 million planned
slots and 41.019 million emitted records. Compact COFF capacities are exact and are allocated
only for used sections. Both avoid the regime-sensitive marked-node estimates rejected in
Wave 1. Even so, lower cumulative allocation does not guarantee lower peak commitment: exact
compact COFF capacity changed collection timing enough to fail the explicit peak-memory guard.

### Wave 3 full-run matrix

| Run | Wall | Graph | Mark | Object | Allocation | Peak private |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Control A | 592.87 s | 401.21 s | 356.54 s | 188.01 s | 114.09 GiB | 34.41 GiB |
| Indexed dependency lists | 592.87 s | 396.41 s | 350.15 s | 192.30 s | 112.70 GiB | 33.82 GiB |
| Reference conditional buckets | 620.07 s | 419.07 s | 372.13 s | 196.83 s | 113.39 GiB | 34.74 GiB |
| Control B | 604.78 s | 406.28 s | 358.49 s | 194.44 s | 114.05 GiB | 35.72 GiB |
| Exact symbolic capacity | 616.05 s | 421.09 s | 373.70 s | 191.53 s | 113.58 GiB | 35.61 GiB |
| Exact compact capacity | 598.16 s | 408.70 s | 361.39 s | 185.14 s | 113.10 GiB | 37.17 GiB |
| Control C | 618.38 s | 423.05 s | 376.53 s | 191.72 s | 114.11 GiB | 35.26 GiB |
| Compact relocation blocks | 608.48 s | 410.30 s | 363.59 s | 194.80 s | 113.88 GiB | 34.24 GiB |
| Control D | 598.29 s | 411.86 s | 366.08 s | 182.89 s | 114.08 GiB | 33.77 GiB |
| Exact compact confirmation | 588.46 s | 401.57 s | 354.29 s | 182.80 s | 113.10 GiB | 35.38 GiB |
| Conditional confirmation | 588.31 s | 405.10 s | 356.96 s | 179.37 s | 113.38 GiB | 36.88 GiB |

### Final all-wave combination

The final accepted set was:

```text
compact-section-data;lazy-relocation-lists;string-table-hashset;compact-coff-relocations;
dependency-list-indexed-iteration;conditional-single-reference-bucket;
exact-symbolic-relocation-capacity
```

Controls D and E bracketed the combined run. The combined run began at 85% reported maximum
frequency, between D at 90% and E at 84%.

| Metric | Control D/E midpoint | Combined | Change |
| --- | ---: | ---: | ---: |
| Total wall | 603.497 s | 599.366 s | -4.131 s (-0.68%) |
| Graph and code generation | 408.416 s | 406.551 s | -1.865 s (-0.46%) |
| Mark stack | 363.013 s | 359.783 s | -3.230 s (-0.89%) |
| Deferred computation | 36.342 s | 36.635 s | +0.293 s (+0.81%) |
| Object emission | 191.191 s | 189.275 s | -1.916 s (-1.00%) |
| Node materialization | 111.327 s | 106.823 s | -4.504 s (-4.05%) |
| Capacity planning | 0 s | 0.192 s | +0.192 s |
| Relocation resolution | 18.929 s | 21.846 s | +2.917 s (+15.41%) |
| Object file write | 44.936 s | 44.462 s | -0.474 s (-1.05%) |
| Managed allocation | 114.104 GiB | 111.470 GiB | -2.634 GiB (-2.31%) |

Peak private memory was 35.611 GiB versus 33.766/34.514 GiB in the controls. The higher peak
was transient late in object writing. Phase-aligned samples were lower than control D at graph
end (16.69 versus 17.20 GiB), materialization end (28.90 versus 29.89 GiB), and object end
(32.16 versus 33.62 GiB). The result is therefore retained-heap/GC-shape variability rather
than evidence of higher cumulative allocation, but it remains a deployment-capacity caveat.

The final object linked successfully in 53.89 seconds to a 1,038,627,840-byte executable with
SHA-256 `D009CB3EDF31E457C93C6FE99520A53F64C26D7CD39F58A57624A3CB9E854819`.
The executable remained alive through a 20-second GUI startup smoke test and was then stopped
by its exact process ID. The compiler build succeeded and `ILCompiler.Compiler.Tests` passed
21 of 21 tests with the accepted gates enabled. The profiled compiler `ilc.dll` SHA-256 was
`5B7631836D6C43746DBF638299C348E163D0F0E70A58450CDFB5EA47D0863E45`.
After review-only fixes to rejected/combined-only paths, the rebuilt `ilc.dll` SHA-256 is
`5ED0F11545AB936623848A0EEADF66296FFAC0C4973CAF7A9F241A58EBF74700`; it reproduced the
accepted EntryModel object's exact 95,437,303-byte
`1CCCD378360DC0F9B1766083060B24F7BC593CEE42F1C70DC9F80687D2A507BC` hash.

Raw profiles are under `artifacts\nativeaot-profile\experiments\wave3-full-rdm`; the summary is
`artifacts\nativeaot-profile\experiments\wave3-full-rdm-summary.csv`. Link and smoke evidence
are in `11-combined-all-waves\link-metadata.json` and `smoke-metadata.json`.

## Fifteen-experiment verdict ledger

| Wave | Experiment | Verdict |
| --- | --- | --- |
| 1 | Filtered final graph sort | Regression |
| 1 | Null-interner fast path | Neutral |
| 1 | Lazy per-section state | Win: allocation and modest object time |
| 1 | Eager object-writer preallocation | Neutral/unstable |
| 1 | Hash-based COFF string reservation | Win: targeted string-reservation time |
| 2 | Conditional singleton value bucket | Regression |
| 2 | Batched COFF writes | Neutral |
| 2 | Fast long-name classification | Regression |
| 2 | Compact COFF relocations | Win: allocation; wall neutral |
| 2 | Compact COFF symbols | Regression despite lower allocation |
| 3 | Concrete dependency-list iteration | Win: graph time and allocation |
| 3 | Reference-backed conditional bucket | Win: allocation; provisional graph time |
| 3 | Planned symbolic-relocation capacity | Win: allocation; timing neutral |
| 3 | Exact compact COFF capacity | Rejected: peak-memory regression |
| 3 | Compact relocation blocks | Neutral; modest allocation only |

### Priorities after three waves

1. **Reduce dependency graph construction and allocation.** It remains about 405-410 seconds.
   The concrete-iteration win shows that collection API shape matters at 170 million edges.
   Return concrete/span-compatible dependency collections, avoid boxed enumerators, and
   profile node-factory/interning allocations by type before attempting broader parallelism.
2. **Reduce RDM roots.** Generated ViewLocator registrations, serializer breadth, and optional
   Graph/OpenXML/AI modules multiply the graph itself. Compiler improvements make every node
   cheaper; removing unnecessary roots avoids all downstream graph, metadata, code, symbol,
   relocation, and link work.
3. **Stream deterministic object materialization.** The accepted object changes save
   allocation, but 13.455 million object nodes, 18.258 million symbols, and 41.019 million COFF
   relocations remain live enough for GC and file-cache effects to dominate. Partitioned
   preparation followed by deterministic streaming has a larger ceiling than additional tiny
   name or write fast paths.
4. **Prototype cross-run caching.** The single giant object prevents reuse. A correctness-keyed
   cache for method/object fragments and dependency facts has the largest repeat-build ceiling,
   but requires architectural work around reflection, generic dictionaries, and deterministic
   merging.
5. **Do not prioritize method-worker or linker tuning.** Method batches remain a small,
   already-parallel fraction; linking remains tens of seconds. Neither addresses the measured
   serial graph and object costs.

## Reproduction

1. Check out runtime tag `v10.0.11`.
2. Apply `ilc-v10.0.11-profile.patch`.
3. Build with `Build-LocalToolchain.ps1`.
4. Run `Invoke-RdmPublish.ps1` with a short output root to restore/publish and retain the
   MSBuild binlog and ILC response.
5. Run `Invoke-IlcProfile.ps1` on the retained response. Omit `-ProfileMethods` for the
   authoritative phase profile; add it only for an intrusive ranking run. Pass experiment
   gates with `-Experiments`, for example:

   ```powershell
   -Experiments lazy-relocation-lists,compact-section-data,string-table-hashset,`
       compact-coff-relocations,dependency-list-indexed-iteration,`
       conditional-single-reference-bucket,exact-symbolic-relocation-capacity
   ```

6. Run `Analyze-IlcProfile.ps1` to produce compact CSV summaries.

Bulky profile outputs belong under `artifacts/` or another ignored directory, not source
control.
