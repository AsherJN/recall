# Real Metal binary-archive proof

Run a bounded native Metal experiment without starting Wine or Overwatch:

```sh
python3 tests/pipeline_cache/run_metal.py
python3 tests/pipeline_cache/run_metal.py --arch x86_64
```

The runner compiles a standalone Objective-C executable from
`metal_archive_probe.m` and saves bounded artifacts under
`logs/dxmt/metal-archive-proof-TIMESTAMP`. The first command executes arm64 code;
the second executes the x86_64 host architecture used by our Wine Metal bridge.
The default is twelve samples per mechanism, configurable from 1 to 32 with
`--samples`. The test never disables or clears the system Metal cache, changes
game settings, modifies game shader caches, or controls any application window.

Every run uses a random nonce in its MSL function identities and shader content.
This prevents a previously captured test archive from satisfying the new proof.
The runner:

1. Creates a real GPU pipeline for a full-screen triangle, adds its descriptor
   to an `MTLBinaryArchive`, checks the Boolean/error results, and serializes it.
2. Starts a fresh process for each matched pipeline creation. Explicit archive
   lookup requires `MTLPipelineOptionFailOnBinaryArchiveMiss` to succeed, proving
   the saved archive contains the needed compiled pipeline. The control keeps
   Metal's default framework cache enabled and uses the identical descriptor
   and shader functions. A/B order alternates each repeat.
3. Changes the fragment function to a previously unseen shader. Strict archive
   lookup must fail, and normal fallback compilation must still render the
   expected different color.
4. Checks recoverable cache errors: missing/corrupt archive load, a valid API
   descriptor whose shader stage interfaces cannot link during archive-add,
   and serialization beneath a nonexistent directory. A normal uncached lookup
   afterward must still render correctly.
5. Renders each successful PSO into a private RGBA8 texture, copies it to a shared
   buffer, waits for that standalone command, and checks three pixel samples.

Library compilation, PSO creation, archive-add, archive-load, and serialization
times are reported separately. `results.jsonl` contains all individual samples;
`summary.json` contains source/binary hashes and compiler invocation. This is
native Metal mechanism validation, not a test of DXMT integration, descriptor
ownership, mesh/tessellation support, prewarming, or Overwatch performance.

The first successful arm64 run, `metal-archive-proof-20260911-151048`, measured
0.278 ms median explicit-archive creation versus 0.633 ms with the already warm
default framework cache. Its first uncached pipeline took 15.38 ms. Archive-add
took 0.176 ms, serialization 8.136 ms, and the archive used 22,944 bytes. All
twelve explicit lookups, negative cases, fallbacks, and pixel checks passed.
These numbers concern one tiny pipeline and do not predict gameplay gains.

The x86_64 run, `metal-archive-proof-20260911-151130`, also passed every check.
Explicit lookup had a 1.064 ms median versus 1.459 ms with the default cache.
However, archive loading itself cost 0.607 ms: median load-plus-first-creation was
1.675 ms, so this one-pipeline process did not improve overall. A persistent
archive manager must amortize loading across multiple pipelines. Its cold PSO
took 17.68 ms, archive-add 1.802 ms, and serialization 14.435 ms. This is also
why storage/capture work must not be added unmeasured to gameplay waits.

An initial discarded negative test used a null vertex function. Metal's API
validation correctly aborted that separate test process; it was not a recoverable
archive error. The final suite uses a shader-link failure instead, which produces
a checked NSError and allows fallback validation to proceed.

## Production recipe codec and manager

```sh
python3 tests/pipeline_cache/run_recipe_render.py
python3 tests/pipeline_cache/run_manager_render.py --sanitize
```

Both default to x86_64, matching the native bridge's host architecture. They use
command-line `metal` and `metallib` to create actual binary library fixtures;
runtime MSL-source libraries would not test the persisted byte-based recipe
path. Neither invokes an Xcode project or opens the IDE.

`run_recipe_render.py` compiles the production `pipeline_recipe.c`, registers the
real library/function identities, captures and encodes a render recipe, restores
the descriptor/functions from the saved library bytes, and compares actual GPU
pixel output. Corrupt persisted library bytes must be rejected before normal
rendering falls back successfully. The first passing artifact is
`recipe-render-proof-20260911-151909`.

`run_manager_render.py` builds the actual `pipeline_cache.c` and codec together
as a native dylib so that the production module-pinning path also executes. It
uses a private cache root and separate processes for these cases:

- Cold learning persists a library and recipe, produces correct pixels, reuses
  the same retained PSO on a second lookup, and performs **zero archive-adds**.
- The next process prepares the known recipe during startup and returns that
  completed object for both runtime lookups, with zero runtime PSO creations.
- A subsequent process proves an explicit archive hit during prewarming and
  avoids adding an already captured pipeline again.
- A zero startup-time budget performs no prewarming or archive-adds, while
  normal runtime creation and reuse continue to work.
- Separately corrupted library bytes, recipe JSON, and archive bytes all retain
  correct fallback rendering. After rebuilding a corrupted archive, the next
  process must prove that the repaired file supports a strict archive hit.
- Disabled caching produces no manager logs and preserves normal rendering.
- Three learned recipes with a one-recipe startup limit prepare a different
  missing combination on each of three launches. The manifest coverage must
  grow from one to two to three keys. A final launch preparing all three must
  prove three strict archive hits, six memory PSO hits, zero runtime creations,
  and zero redundant archive-adds, with correct pixels for all three colors.
- With three distinct library files, deleting only the most expensive recipe's
  AIR dependency must not consume the one-recipe startup limit: a lower-ranked
  valid recipe must still be prepared, and normal fallback renders all colors.
- Preparing all three distinct-library recipes together tests fresh archive
  population and subsequent strict hits using the actual manager's descriptor
  ownership and release behavior.

Every managed successful path renders and reads three pixels twice; enabled
cache hits must return the same native PSO identity. Tests wait for the real
periodic persistence/summary worker and do not call a test-only flush. Source
hashes are captured before compilation and the report flags concurrent source
changes. The sanitizer option enables AddressSanitizer and UndefinedBehaviorSanitizer
for the actual manager, codec, and harness. Leak reporting is disabled because
the production manager and module pin intentionally have process lifetime.

`pipeline-manager-proof-20260911-152301` passed all nine cases under sanitizers
with unchanged source during the run. These checks caught and led to fixes for
Metal's lazily created empty vertex descriptor being incorrectly rejected and
an existing corrupt archive file being trusted solely by its hash-shaped name.

The three-recipe progression also passed under sanitizers in intermediate
artifact `pipeline-manager-proof-20260911-152645`; it proves the startup cap does
not trap archive coverage on the same already prepared entry forever.

The final immutable-batch manager passed all seventeen cases under x86_64
ASan/UBSan in `pipeline-manager-proof-20260911-154101`, with unchanged production
source during the run (`pipeline_cache.c` SHA-256
`0a437cf67c7f1e516f6c33c764887504f23acf4507dbac8eec90efee2da18d1b`).
Three distinct-library recipes succeeded both in one fresh batch and across
three one-recipe startup batches. The final fresh process reported three strict
archive hits, six retained-PSO hits, zero runtime creations, and zero archive
adds, with correct GPU readback. Missing-library fairness and corrupt-archive
repair followed by another process's strict archive hit also passed.

The manager tests use up to three small render recipes. They do not establish
gameplay gains, resource behavior with thousands of pipelines, Wine bridge
integration, or mesh/tessellation support. The startup budget limits when new
work starts; an already executing Metal call cannot be forcibly canceled.

## Native archive-extension regression

```sh
python3 tests/pipeline_cache/run_archive_extension.py \
  --fixture-dir logs/dxmt/pipeline-manager-proof-20260911-153027
```

The fixture directory must come from a current manager run and contain three
generated library files. This probe uses Metal directly, with no production
manager/codec. It distinguishes fresh multi-library archive creation from
extending an archive loaded from disk, and checks persisted archive hits with
actual rendered pixels.

On this M1 Pro/macOS 26.6.2, `metal-archive-extension-20260911-153838` reproduced
an `MTLBinaryArchiveDomain` code 3 serialization failure when extending a loaded
archive with a pipeline from another library. Archive-add itself succeeded.
Loading/retaining the original descriptor/library, or adding the original recipe
again, did not resolve it. Fresh archives containing two or three distinct
libraries serialized correctly, and all three fresh-process strict lookups
rendered the expected pixels. This supports immutable fresh archive batches;
it does not justify treating a failed serialization as successful persistence.
The runner records seeded-extension behavior without requiring that future
driver versions retain this failure.
