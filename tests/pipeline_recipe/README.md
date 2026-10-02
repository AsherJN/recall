# Graphics pipeline recipe codec checks

Run `python3 tests/pipeline_recipe/run.py` from the workspace root. It compiles the
actual native `pipeline_recipe.c` with AddressSanitizer and UndefinedBehaviorSanitizer,
real Metal descriptor objects, and deterministic fake library/function/device objects.
It does not use Xcode or build a game executable.

The checks cover 156 independent scalar, attachment and buffer-mutability changes;
each changes the recipe identity and survives encode/decode, descriptor reconstruction
and recapture. Library content and function names affect identity, while structure
padding and dictionary insertion order do not. Fragment-less pipelines round-trip.
Malformed schemas, unknown fields, invalid numbers, oversized inputs, missing/corrupt
library bytes and mismatched function identities fail closed. Corrupt library bytes
are rejected before the fake Metal loader is called.

The harness also checks caller archive contracts, nondefault vertex layouts, cleared
specialized/source metadata, rejected persistence, and the 8 MiB library cap. Two
threads repeatedly revoke/register metadata and capture recipes to exercise atomic
association lifetime. The runtime may lazily return a nonnil *empty* vertex descriptor;
the codec accepts its exact default state and rejects nondefault attributes or layouts.

These codec tests do not prove GPU pipeline correctness: `tests/pipeline_cache`
separately uses real compiled Metal libraries, native GPU rendering and readback,
plus persistent-cache replay across processes. Only standard graphics recipes are
supported. Unknown functions, specialized functions, source-only libraries, vertex
layouts, linked/preloaded libraries and caller-owned archive contracts bypass this
cache without modifying the original rendering request.

Registered library/function metadata retains only content identities and function
names. A full persistence queue may drop temporary library bytes without revoking
their valid identity or preventing current pipeline reuse. Future restoration
rejects missing bytes and verifies every library's complete SHA-256 digest.
Recipe JSON is limited to 64 KiB and uses a strict versioned schema with sorted keys.
The cache manager additionally isolates files by build, OS and GPU identity.
