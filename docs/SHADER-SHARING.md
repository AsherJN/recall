# Experimental DXMT shader learning exchange

In Settings → Graphics, use Share shader learning. Close Battle.net and Overwatch on both Macs.

1. Export to a new empty folder. Send the entire folder to the other Mac.
2. Import and Merge on the destination. Existing recipes are kept; new content-addressed recipes and AIR libraries are added.
3. Import starts local pipeline preparation. Wait for preparation to finish before playing; do not assume that accepting the import means every pipeline compiled successfully. The existing preparation system has budgets and may prepare only a subset.
4. Export the combined collection to another empty folder and send it back. Repeated imports deduplicate rather than overwrite.

Only recipe JSON and referenced AIR libraries are exported. GPU binary archives, account information, game files, logs and absolute source paths are excluded. Both Macs must use the same Recall runtime and exact macOS version. GPU identity intentionally differs: each Mac receives the learning in its own device namespace. Matching game versions and settings are recommended; game build identity is not currently checked by the importer.

Import only from a trusted person: hashes check integrity, not authenticity or driver safety. Validation checks file types, sizes, names, hashes, recipe identities and library dependencies. The native DXMT preparation decoder performs further validation. Imports are additive, not a whole-cache transaction: an interrupted write may leave a partial import; existing files are not intentionally replaced. Keep a backup before experimental use. An incomplete export has no completed manifest and should be exported again into a fresh empty folder.

Validation so far uses synthetic records and does not prove real AIR portability or eliminate stutter. Actual M5 Max → M5 transfer and local compilation still require a two-machine test. No upstream DXMT source changes are made.
