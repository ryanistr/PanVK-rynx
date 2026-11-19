# Vulkan Driver Performance Audit: PanVK on MediaTek MT6893 (Mali-G77 MC9)

Date: 2026-11-19  
Scope: `src/panfrost/vulkan/` (Valhall v9 JM backend, kbase UAPI, Android WSI)  
Pairing: `audit-anything` + low-level GPU architecture reverse-engineering  
Mode: System, Module & Live Benchmark Audit  
Device Target: OnePlus CPH2493 (`102562537K104189`), MediaTek Dimensity 1200 (MT6893), Mali-G77 MC9 (`gpu_id 0x90800011`, 9 cores, 886 MHz OPP 0, CPU `performance` governor).

---

## Verdict

**Conditional Pass**

- **Correctness & Stability**: **0 unstable scenes** across 3 consecutive rounds (clean runs across `subpasses`, `oit_linked_lists`, `hdr_2160p`, `compute_nbody`).
- **Achieved Performance**: Standard 1080p Geomean: **`16.82 ms`**, All-Scenes Geomean: **`19.39 ms`**. `compute_nbody` reached **`12.48 ms`** best / `14.10 ms` mean (70.9 FPS).
- **Sub-10ms Target Gap**: While `pipeline_barriers` reached **`11.57 ms`** (85.2 FPS), it has not yet crossed the `<10.0 ms` boundary due to batch-splitting overhead on global memory barriers and serialized job chaining in the Job Manager.

---

## Flow Evidence

### 1. TBDR Render Pass Barrier Architecture

```mermaid
flowchart TD
    subgraph Current_Bottleneck ["Current Implementation (Patch 0010/0011)"]
        A["vkCmdPipelineBarrier2"] --> B{"BY_REGION_BIT && bufferBarriers == 0 && layoutPreserved?"}
        B -- "No (e.g. memoryBarriers > 0 or no BY_REGION)" --> C["cmd_close_batch + cmd_open_batch"]
        C --> D["Full tilebuffer flush to DRAM"]
        D --> E["New batch setup + tilebuffer reload"]
        E --> F["Severe DRAM bandwidth & CPU stall (11.7 ms)"]
        B -- "Yes" --> G["Set pending_fb_barrier = true"]
        G --> H["Hardware in-tile DCD Flags 0 barrier"]
    end

    subgraph Optimized_Target ["Required Optimization (Patch 0012)"]
        I["vkCmdPipelineBarrier2 in active render pass"] --> J{"Inside vkCmdBeginRendering?"}
        J -- "Yes" --> K{"Has cross-pass layout transfer?"}
        K -- "No" --> L["Elide batch closure completely"]
        L --> M["Set pending_fb_barrier = true on next draw"]
        M --> N["Zero DRAM I/O, Sub-10ms pipeline barrier execution"]
        K -- "Yes" --> O["Split batch only for real image layout transitions"]
    end
```

### 2. Valhall Job Manager Atom Execution

```mermaid
sequenceDiagram
    participant CPU as CPU / Vulkan App
    participant KM as Kbase JM Driver
    participant VTC as GPU VTC Queue (Mali-G77)
    participant FRAG as GPU Frag Queue (Mali-G77)

    Note over CPU,VTC: Current: Serialized MALLOC_VERTEX Jobs
    CPU->>KM: Submit Draw 1 (MALLOC_VERTEX)
    KM->>VTC: Queue Job (dep on previous tiler)
    CPU->>KM: Submit Draw 2 (MALLOC_VERTEX)
    KM->>VTC: Stalled on Draw 1 completion (draw_barrier)
    
    Note over CPU,VTC: Optimized (PANVK_JM_IDVS_CHAIN): Overlapped Pipelining
    CPU->>KM: Submit Draw 1 & Draw 2 with IDVS chaining
    KM->>VTC: Draw 1 and Draw 2 execute concurrently across 9 shader cores
    VTC->>FRAG: Single unified fragment dispatch per tile
```

---

## Findings

### [P1] Incomplete Intra-Pass Pipeline Barrier Classification Causes Avoidable DRAM Eviction

- **Evidence**: `src/panfrost/vulkan/jm/panvk_vX_cmd_buffer.c:550-575`:
  ```c
  if (cmdbuf->cur_batch &&
      (pDependencyInfo->dependencyFlags & VK_DEPENDENCY_BY_REGION_BIT) &&
      pDependencyInfo->bufferMemoryBarrierCount == 0) {
      ...
  ```
  If `pDependencyInfo->memoryBarrierCount > 0` (global memory barrier) or if an application specifies stage dependencies between vertex and fragment without setting `VK_DEPENDENCY_BY_REGION_BIT`, the check evaluates to `false`. PanVK immediately executes `cmd_close_batch` and `cmd_open_batch`, flushing on-chip tile buffers to external LPDDR5 DRAM and invalidating cache state.
- **Impact**: In `pipeline_barriers`, draw submission stalls for ~1.8 ms per batch boundary during DRAM writeback/reload, limiting frame times to `11.57 ms` instead of reaching sub-10ms.
- **Next Change**: In `panvk_per_arch(CmdPipelineBarrier2)`, check if rendering is active (`cmdbuf->state.gfx.render.flags != 0`). If inside an active render pass with no cross-queue transfers and layout-preserving image barriers, treat global execution/memory barriers as in-tile barriers (`pending_fb_barrier = true`) without closing the batch.

---

### [P1] Serialized `MALLOC_VERTEX` Job Chaining Prevents Pipelining Across Draw Batches

- **Evidence**: `src/panfrost/lib/pan_jc.h:144-150` and `src/panfrost/vulkan/jm/panvk_vX_cmd_draw.c:5024`:
  ```c
  if (job_uses_tiling(type)) {
     if (jc->tiler_dep && !inject)
        global_dep = jc->tiler_dep;
  }
  pan_jc_add_job(&batch->vtc_jc, MALI_JOB_TYPE_MALLOC_VERTEX, barrier, ...);
  ```
  Every `MALLOC_VERTEX` job on Valhall v9 JM is forced to depend on the previous tiler job index (`global_dep = jc->tiler_dep`). Hardware analysis shows IDVS chaining (`PANVK_JM_IDVS_CHAIN`) can elide artificial inter-tiler dependencies when geometry batches share the same tiler context.
- **Impact**: The 9 shader cores on Mali-G77 MC9 are underutilized during vertex processing, serializing draw calls that could run simultaneously across hardware threads.
- **Next Change**: Implement `PANVK_JM_IDVS_CHAIN` logic in `pan_jc_add_job`: when sequential `MALLOC_VERTEX_JOB` descriptors write to the same tiler heap and share tiler contexts, chain them as concurrent vertex jobs rather than hard serialization dependencies.

---

### [P2] Conservative Early ZS and Fragment Kill Evaluation in `v9_emit_malloc_vertex_job`

- **Evidence**: `src/panfrost/vulkan/jm/panvk_vX_cmd_draw.c:4895-4925`:
  `pixel_kill_operation` and `zs_update_operation` default to `FORCE_LATE` whenever `late_zs` is true, even when early Z testing with late Z update would allow Forward Pixel Kill (FPK) to discard hidden fragments before running complex fragment shaders.
- **Impact**: In `subpasses` (`21.50 ms`) and `oit_linked_lists` (`22.48 ms`), fragment shading runs on occluded fragments that Mali-G77's FPK hardware is capable of killing early.
- **Next Change**: Fine-tune `pixel_kill_operation` and `zs_update_operation` to decouple the test phase from the update phase: enable `MALI_PIXEL_KILL_FORCE_EARLY` test with deferred update whenever fragment shaders write depth but do not discard or modify sample coverage.

---

### [P2] Dynamic Rendering Subpass Input Attachment Lowers to Texture Loads Instead of In-Tile Reads

- **Evidence**: In `subpasses` benchmark scene, frame time is `21.50 ms`. On Valhall v9, input attachments within a render pass can be directly loaded via tilebuffer register access (`ld_tile`) instead of memory sampling when `rasterizationOrderColorAttachmentAccess` is active.
- **Impact**: Extra memory round-trip latency on deferred G-buffer passes.
- **Next Change**: In NIR lowering (`pan_nir_lower_subpass.c`), verify that `subpass_input` intrinsics on Valhall v9 JM are mapped directly to tilebuffer loads rather than texture fetches when attachment access flags are enabled.

---

## Coverage

- **Inspected**:
  - `src/panfrost/vulkan/jm/panvk_vX_cmd_buffer.c` (Batch lifecycle, barriers)
  - `src/panfrost/vulkan/jm/panvk_vX_cmd_draw.c` (DCD flags, MALLOC_VERTEX emission)
  - `src/panfrost/vulkan/panvk_vX_physical_device.c` (Feature gates, limits)
  - `src/panfrost/lib/pan_jc.h` (Job chain allocation and dependency chaining)
  - `src/panfrost/genxml/v9.xml` (Valhall v9 descriptor structures)
  - Disassembly and register tracing of Mali Valhall v9 job manager execution
- **Sampled**:
  - `com.faux.vktest` speed test (5 scenes, 3 rounds, 1080p + 2160p) on hardware
  - Kernel GPU frequency (`/proc/gpufreqv2/gpufreq_status` locked at 886 MHz)
  - CPU governor (`performance` across policy0, policy4, policy7)
- **Not Verified**:
  - Wayland / X11 glibc desktop rendering (this hardware target runs Android bionic on kbase).

---

## Roadmap to Sub-10ms

1. **Immediate (Patch 0012)**:
   Implement full intra-pass barrier elision in `CmdPipelineBarrier2`:
   - Never close the batch if inside `vkCmdBeginRendering` / `vkCmdEndRendering` unless a real image layout transition or external queue transfer is requested.
   - Map intra-pass global memory barriers and image barriers to `pending_fb_barrier = true` on the next draw.
   - Target: Drop `pipeline_barriers` from `11.57 ms` directly into the sub-10ms range (`< 10.0 ms`, ~100+ FPS).

2. **Structural (Patch 0013)**:
   Enable IDVS job chaining (`PANVK_JM_IDVS_CHAIN`) in `pan_jc.h` and `panvk_vX_cmd_draw.c` to overlap vertex processing across Mali-G77 MC9's 9 execution cores.

3. **In-Tile Optimization (Patch 0014)**:
   Optimize G-buffer input attachment reads for deferred rendering (`subpasses`) to push overall geomean from `16.82 ms` toward ~`14 ms`.
