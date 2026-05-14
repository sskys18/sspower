# Index Provider Registration — Phase 0 Source Verification

> Source: https://github.com/mem0ai/mem0 @ `70bc9e51d57fe005d02b7b6d81b56476bade3cb3` (UTC 2026-05-13T09:01:15Z; committer ts 1778662875)
> Companion to docs/specs/2026-05-13-index-backend-integration-design.md (v8)
> Author: phase-0-research-agent, 2026-05-14

## 0. Methodology

Cloned `git clone --depth=1 https://github.com/mem0ai/mem0.git` into `/tmp/sspower-phase0/upstream`. Read in full or in citation-relevant slices:

- `mem0/utils/factory.py` (full, 265 lines) — Q1, Q2 ground truth.
- `mem0/memory/main.py` (target slices: 1-120, 231-411, 573-971, 1126-1340, 1480-1750) — Q3, Q6, Q7, Q8.
- `mem0/configs/base.py` lines 13, 30-58 — Q4.
- `mem0/memory/setup.py` lines 10-17 — Q4 default path + `MEM0_DIR` env.
- `mem0/memory/telemetry.py` (full, 235 lines) — Q5.
- `mem0/vector_stores/chroma.py` lines 143-332 (search + `_generate_where_clause`) — Q8 pass-through.

Did NOT read: `mem0/memory/main.py` async paths beyond verifying parity with sync (lines 2003+ mirror `_add_to_vector_store`); other vector-store backends; any LLM/embedder provider source. Sandbox: read-only, no Python interpreter run — so all conclusions are static-analysis from primary source, not runtime confirmed.

## 1. Custom-LLM registration — answer Q1

**Mechanism (a) is officially supported via a public API.** No monkey-patch required.

`mem0/utils/factory.py` lines 30-56 show `LlmFactory.provider_to_class` is a plain class-level `dict`. Lines 114-126 expose a public class method:

```python
@classmethod
def register_provider(cls, name: str, class_path: str, config_class=None):
    """
    Register a new provider.
    ...
    """
    if config_class is None:
        config_class = BaseLlmConfig
    cls.provider_to_class[name] = (class_path, config_class)
```

Lines 58-112 (`create`) read this dict at call time, so any registration before the first `Memory(...)` construction (or even between constructions) takes effect. The class is importable from upstream `mem0/utils/factory.py` and the dict mutation is permanent for the process.

**Evidence (a) viable**: `provider_to_class` is `dict` (line 37), `register_provider` is a `@classmethod` writing to it (line 126), and `create` looks up at runtime (line 74-77).

**Evidence (b) viable as fallback only**: `Memory.__init__` assigns `self.llm = LlmFactory.create(...)` (main.py line 343). After-init `memory_instance.llm = MyLLM()` would work for the V3 extract path (`self.llm.generate_response`, line 739), but breaks any future code that re-creates `self.llm` (e.g., `Memory.reset()` does NOT, but a subclass might).

**Evidence (c) fork is unnecessary**: the public API at line 114 is sufficient.

**Decision**: Use mechanism (a) — call `LlmFactory.register_provider("sspower-codex", "sspower.mem.llm.CodexLLM", BaseLlmConfig)` once at module import. The wrapped LLM must subclass `mem0.llms.base.LLMBase` and implement `generate_response`. No upstream code changes.

## 2. Custom-embedder registration — answer Q2

**Mechanism (a) — class-dict mutation — is the ONLY mechanism. No public `register_provider` exists.**

`mem0/utils/factory.py` lines 139-164 show `EmbedderFactory.provider_to_class` is a plain `dict[str, str]` (path-only, no config-class tuple). There is no `register_provider` classmethod. Lines 154-164 (`create`):

```python
@classmethod
def create(cls, provider_name, config, vector_config: Optional[dict]):
    if provider_name == "upstash_vector" and vector_config and vector_config.enable_embeddings:
        return MockEmbeddings()
    class_type = cls.provider_to_class.get(provider_name)
    if class_type:
        embedder_instance = load_class(class_type)
        base_config = BaseEmbedderConfig(**config)
        return embedder_instance(base_config)
    else:
        raise ValueError(f"Unsupported Embedder provider: {provider_name}")
```

Mutating the dict directly works:

```python
EmbedderFactory.provider_to_class["sspower-codex"] = "sspower.mem.embedder.CodexEmbedder"
```

**Caveat 1**: `BaseEmbedderConfig(**config)` at line 161 means the custom embedder receives a `BaseEmbedderConfig` instance (NOT a custom config class). The wrapped class must accept a `BaseEmbedderConfig` constructor arg — restrict custom config to fields already on `BaseEmbedderConfig` (`mem0/configs/embeddings/base.py`).

**Caveat 2**: The dict mutation API is private — upstream may rename `provider_to_class` between releases. Pin upstream version in sspower's `pyproject.toml`/lockfile.

**Decision**: Mechanism (a) — direct dict mutation at module import. File a feature request upstream proposing `EmbedderFactory.register_provider` parity with `LlmFactory`; until merged, accept the private-API risk.

## 3. `Memory.add(infer=False)` exact semantics — answer Q3

`mem0/memory/main.py:573-697` (`add` + `_add_to_vector_store` infer=False branch).

| Aspect | Behavior | Citation |
|---|---|---|
| Storage path | Same Chroma collection as `infer=True` (`self.vector_store`) — there is no separate "raw" collection. | line 686: `mem_id = self._create_memory(msg_content, ...)` → line 1601: `self.vector_store.insert(...)` |
| Returned ids | `{"results": [{"id": "<uuid>", "memory": "<content>", "event": "ADD", "actor_id": <name or None>, "role": "<msg-role>"}, ...]}`. One entry per non-system message in `messages`. | lines 660, 688-696 |
| Embedder use | YES — every message content is embedded via `self.embedding_model.embed(msg_content, "add")` (line 685). Raw mode skips the LLM, NOT the embedder. |
| Caller metadata preservation | Caller `metadata` is `deepcopy`'d per message (line 677), then mutated to add `role` and optional `actor_id`. After `_create_memory` runs, the stored payload is further enriched with `data`, `hash`, `created_at`, `updated_at`, `text_lemmatized` (lines 1593-1599). Caller-supplied keys (e.g., `raw_id`, `kind`, `id`, `layer`, `scope`, `ts`) are preserved verbatim — `_create_memory` only `setdefault`s on `created_at` and overwrites `data`/`hash`/`updated_at`/`text_lemmatized`. |
| Required filters | `user_id` OR `agent_id` OR `run_id` is required (raises `Mem0ValidationError` otherwise — `_build_filters_and_metadata` line 301-307). |
| System messages | Silently skipped (line 674-675). |

**Implication for sspower**: a caller-supplied `id` field in `metadata` will be preserved in the payload but will NOT override the auto-generated `mem_id` (which is `str(uuid.uuid4())` at line 1592). To dedup by sspower's own `block_id`, write it under a non-conflicting key (`raw_id`, `block_id`) and filter by it via `Memory.search(filters={"block_id": "<id>"})` (see Q8).

## 4. SQLite history-DB path override — answer Q4

**Three options, all official.**

1. **Config field**: `MemoryConfig.history_db_path` (`mem0/configs/base.py` line 42-45) — pass via `Memory(MemoryConfig(history_db_path="/Users/sskys/.claude/sspower/idx/history.db"))`.
2. **Env var (default-only)**: `MEM0_DIR` env (`mem0/configs/base.py` line 13: `mem0_dir = os.environ.get("MEM0_DIR") or os.path.join(home_dir, ".mem0")`). Setting `MEM0_DIR=/Users/sskys/.claude/sspower/idx` makes the default `history.db` resolve under that dir, but ONLY if `history_db_path` is left at default. Same env affects `migrations_qdrant`/`migrations_faiss` telemetry directories (main.py line 379) — irrelevant for Chroma but be aware.
3. **Subclass**: not needed.

`Memory.__init__` line 344: `self.db = SQLiteManager(self.config.history_db_path)` — single source.

**Decision**: Use option 1 (explicit `history_db_path`). Cleaner than `MEM0_DIR`; doesn't entangle with telemetry path naming. Set to `~/.claude/sspower/idx/history.db` (resolve `~` before passing).

## 5. Telemetry opt-out — answer Q5

**Env var name (case-sensitive): `MEM0_TELEMETRY`. Read at module import time (line 14). Setting to any of `False`/`false`/`0`/`no` (line 19 `.lower() in ("true", "1", "yes")` — anything outside that set becomes `False`) BEFORE `mem0` is imported is sufficient for `capture_event` (line 192-193) and for `AnonymousTelemetry.__init__` (line 75-78) to skip PostHog client construction entirely.**

```python
# mem0/memory/telemetry.py:14-22
MEM0_TELEMETRY = os.environ.get("MEM0_TELEMETRY", "True")
...
if isinstance(MEM0_TELEMETRY, str):
    MEM0_TELEMETRY = MEM0_TELEMETRY.lower() in ("true", "1", "yes")
```

```python
# mem0/memory/telemetry.py:73-78
class AnonymousTelemetry:
    def __init__(self, vector_store=None, before_send=None):
        if not MEM0_TELEMETRY:
            self.posthog = None
            self.user_id = None
            return
```

```python
# mem0/memory/telemetry.py:182-183
client_telemetry = AnonymousTelemetry()
atexit.register(client_telemetry.close)
```

**Module-level instantiation at line 182 is the catch**: `client_telemetry` is built at import time, BEFORE the user's process gets to set the env var if mem0 is already imported (e.g., by another package). To be safe, sspower must `os.environ["MEM0_TELEMETRY"] = "False"` BEFORE the first `import mem0` in the process.

**Module patch (defensive)**: monkey-patch `mem0.memory.telemetry.capture_event` and `mem0.memory.telemetry.capture_client_event` to no-op functions. This guarantees no PostHog traffic even if env-var ordering is wrong:

```python
import mem0.memory.telemetry as _t
_t.capture_event = lambda *a, **kw: None
_t.capture_client_event = lambda *a, **kw: None
_t.MEM0_TELEMETRY = False
```

**Decision**: env-var name = `MEM0_TELEMETRY` (NOT `MEM0_TELEMETRY=false` per spec assumption — case-insensitive value, but EXACT case-sensitive name). Module patch IS recommended belt-and-braces because of the import-time module-level singleton at line 182. Also patch sample-rate via `MEM0_TELEMETRY_SAMPLE_RATE=0` for additional safety (line 47).

## 6. Entity-store with graph=off — answer Q6

**YES — Mem0 v3 lazily creates an extra collection `<collection_name>_entities` even with no graph store configured. There is NO config flag to disable it.**

`mem0/memory/main.py:357-358` shows `__init__` defers entity-store init:

```python
# Entity store is initialized lazily on first use
self._entity_store = None
```

Lines 389-411 show the lazy property `entity_store` constructs a separate `VectorStoreFactory` instance using the SAME provider as the main vector store but with `collection_name = f"{self.collection_name}_entities"`:

```python
@property
def entity_store(self):
    """Lazily initialize entity store on first use."""
    if self._entity_store is None:
        entity_config = _safe_deepcopy_config(self.config.vector_store.config)
        entity_collection = f"{self.collection_name}_entities"
        if hasattr(entity_config, 'collection_name'):
            entity_config.collection_name = entity_collection
        ...
        self._entity_store = VectorStoreFactory.create(
            self.config.vector_store.provider, entity_config
        )
    return self._entity_store
```

**Trigger**: the property is touched on every `_add_to_vector_store(infer=True)` call at line 905 (`self.entity_store.search_batch(...)`) and on every `_update_memory` / `_delete_memory` via `_remove_memory_from_entity_store` (lines 469-470 short-circuit if `_entity_store is None`, but `_link_entities_for_memory` at line 1718 DOES instantiate it).

**Persistence path**: same as the main Chroma instance (Chroma `path` config), but with collection name `<collection_name>_entities`. For `collection_name="mem0"`, the entity collection is `mem0_entities`.

**Disable mechanism**: NONE exposed via config. Workarounds:

1. **Subclass `Memory`** and override `entity_store` property to return a no-op stub (an object whose `search_batch`/`list`/`insert`/`update`/`delete` methods are no-ops or return `[]`).
2. **Subclass `Memory`** and override `_add_to_vector_store` to skip "Phase 7: Batch entity linking" (lines 866-955) wrapped in a try/except, but this duplicates ~80 lines of code.
3. **Use `infer=False`** exclusively — the raw branch (lines 663-697) does NOT touch `entity_store`. `_create_memory` (line 1586) does not call entity-link helpers either. Confirmed by grep: `_link_entities_for_memory` is called only in `_add_to_vector_store` (extract branch) and `_update_memory`.

**Decision**: For the sspower idx use-case where we use `infer=False` only (raw block storage), the entity-store collection is NEVER created — option 3 is the cleanest answer. If sspower later uses `infer=True`, accept the side-collection (it doesn't break correctness, only adds disk usage and telemetry surface). If full disable is needed, file an upstream issue requesting a `vector_store.entity_store=False` config flag.

## 7. `Memory.add(infer=True)` extract semantics — answer Q7

`mem0/memory/main.py:699-971` (V3 phased batch pipeline).

**Caller metadata preservation across 1-to-N extraction**: YES, fully preserved. Line 808: `mem_metadata = deepcopy(metadata)` for EACH extracted memory. Then lines 809-814 add `data`, `text_lemmatized`, `hash`, `created_at` (only if absent), `updated_at`. Line 815-816 adds `attributed_to` if the LLM included it. **Every caller-supplied key (`raw_id`, `kind`, `id`, `layer`, `scope`, `ts`) is preserved verbatim on every extracted child memory.**

**Caveat**: `id` collision risk — if caller passes `metadata={"id": "<block_id>"}`, the payload's `id` key will hold the caller's value but the vector-store record's primary id is `memory_id = str(uuid.uuid4())` (line 807). They're separate keys; the caller's `id` becomes a regular metadata field, addressable by `filters={"id": "..."}` in `search()`.

**ADD/UPDATE/NONE actions**: **The V3 OSS pipeline emits ONLY `ADD` events.** Lines 960-963:

```python
returned_memories = [
    {"id": r[0], "memory": r[1], "event": "ADD"}
    for r in records
]
```

There is no `UPDATE` or `DELETE` branch in `_add_to_vector_store(infer=True)`. The pipeline:

1. Searches existing memories (line 709) for context.
2. Hashes new texts and dedups against `existing_hashes` (lines 786-803).
3. Inserts only non-duplicates (line 830).

So the assumption in the v8 design that Mem0's extract layer issues UPDATE/NONE is FALSE for this commit. UPDATE only happens via the explicit `Memory.update(memory_id, data)` API (line 1501) called by the user, not by the LLM. (Side note: `_update_memory` at line 1657 DOES preserve session ids from existing payload but REPLACES the rest of the metadata — line 1671 `new_metadata = deepcopy(metadata) if metadata is not None else {}`. So if caller passes `metadata=None` to `update`, all custom keys are LOST. Only `user_id`/`agent_id`/`run_id`/`actor_id`/`role` are auto-preserved from the old payload.)

**LLM exception behavior**: SWALLOWED. Lines 738-748:

```python
try:
    response = self.llm.generate_response(...)
except Exception as e:
    logger.error(f"LLM extraction failed: {e}")
    return []
```

The caller sees an empty `{"results": []}` and a log line at ERROR level. **No exception propagates.** The session messages are NOT saved in this path (the `self.db.save_messages(messages, session_scope)` call at line 767/958 happens only if extraction returned something or extracted_memories was empty by parsing — NOT on the LLM exception return).

**Implications for sspower**:
- Cannot rely on UPDATE/NONE actions from infer=True; must drive idempotency from the caller (sspower) side (e.g., own block-id dedup via search-then-skip).
- Caller metadata propagates 1:N cleanly — fan-out facts inherit `raw_id`/`scope`/`layer`.
- LLM failure is silent; sspower must check for empty `results` and decide whether to retry, fall back to `infer=False`, or surface the failure to the user.

## 8. `Memory.search` metadata-filter API surface — answer Q8

**YES — `Memory.search` accepts arbitrary `metadata.<key>` filters with rich operator support.** No own SQLite dedup db needed; no client-side filter needed; no fork needed.

`mem0/memory/main.py:1126-1161` (`search` docstring) lists supported operators: `eq, ne, in, nin, gt, gte, lt, lte, contains, icontains, AND, OR, NOT, *` (wildcard).

Lines 1180-1197: `effective_filters` MUST contain at least one of `user_id`/`agent_id`/`run_id` (raises `ValueError` otherwise). Beyond that, any additional keys are passed through:

```python
if not any(key in effective_filters for key in ("user_id", "agent_id", "run_id")):
    raise ValueError(...)
```

Lines 1202-1210: advanced operators are processed by `_process_metadata_filters`, then merged into `effective_filters` and passed to `_search_vector_store(query, effective_filters, limit, threshold)` at line 1227.

Chroma pass-through verified at `mem0/vector_stores/chroma.py:158`:

```python
where_clause = self._generate_where_clause(filters) if filters else None
```

`_generate_where_clause` (lines 246-332) translates the universal operator dict to ChromaDB `$eq`/`$ne`/`$gt`/`$in`/`$or`/`$and` syntax. **Caveat**: Chroma does NOT natively support `contains`/`icontains` — the converter falls back to `$eq` (lines 285-287), silently. `NOT` is also dropped (line 316-318: `# ChromaDB doesn't have direct NOT, so we'll skip for now`). For sspower's use case (exact match on `block_id`/`kind`/`raw_id`), this is fine.

**Example for sspower dedup**:

```python
m.search(
    query="<dummy or empty>",
    filters={
        "user_id": "sspower",
        "AND": [
            {"id": "<block_id>"},
            {"kind": "raw"},
        ],
    },
    top_k=1,
    threshold=0.0,
)
```

This translates to a Chroma `$and` query with exact match on `id` and `kind` within the `user_id="sspower"` scope.

**Decision**: Use API-level filter (option 1). No own dedup SQLite needed. No client-side filter needed. No fork needed.

## 9. Decisions for Phase C

- LLM provider registration mechanism: **(a) — `LlmFactory.register_provider("sspower-codex", "sspower.mem.llm.CodexLLM", BaseLlmConfig)`**. Public API, supported.
- Embedder provider registration mechanism: **(a) — direct dict mutation `EmbedderFactory.provider_to_class["sspower-codex"] = "sspower.mem.embedder.CodexEmbedder"`**. Private API; pin upstream version. File upstream issue for `register_provider` parity.
- Telemetry opt-out: env-var name = **`MEM0_TELEMETRY`** (case-sensitive name; case-insensitive value; set to `False`/`0`/`no`/anything-not-in-`{true,1,yes}`). Module patch needed = **YES (defensive)** — patch `mem0.memory.telemetry.capture_event`, `capture_client_event`, and `MEM0_TELEMETRY` in case import-order is wrong. Also set `MEM0_TELEMETRY_SAMPLE_RATE=0`.
- History-db override: **config key `MemoryConfig.history_db_path`**. Set to `~/.claude/sspower/idx/history.db` (expand `~` before passing).
- Entity-store with graph=off: **NOT disable-able via config**. Use `infer=False` exclusively (sspower's primary path) — entity store is never instantiated. If `infer=True` is later needed, accept the `<collection>_entities` side-collection or file upstream feature request.
- Dedup fallback for `Memory.search`: **API filter (option 1)** — `Memory.search(filters={"user_id": ..., "id": "<block_id>", "kind": "raw"})`. Chroma converts cleanly. No own SQLite, no client-side, no fork.
- `infer=True` UPDATE/NONE assumption in v8 spec: **FALSE for this upstream commit** — V3 pipeline emits only ADD events; UPDATE happens only via explicit `Memory.update()`. sspower must drive idempotency from caller side (search-then-skip on `block_id`).
- LLM exception in `infer=True`: **SWALLOWED** → returns `[]`. sspower must check `len(results)==0` and decide: retry / fallback to `infer=False` / surface to user.
- Pinned upstream SHA: **`70bc9e51d57fe005d02b7b6d81b56476bade3cb3`** (UTC 2026-05-13T09:01:15Z).

## 10. Open issues / unresolved

1. **`EmbedderFactory.register_provider` not in upstream** — Phase C should file a feature request at https://github.com/mem0ai/mem0/issues to add `register_provider` parity with `LlmFactory`. Until merged, sspower's dict mutation is a private-API dependency that may break on minor version bumps.

2. **`<collection>_entities` collection cannot be disabled** — even with `infer=False`, future upstream changes may make entity store instantiation eager. Phase C should add a runtime assertion in sspower's bootstrap that fails loudly if the entities collection appears in Chroma. File upstream issue requesting `vector_store.entity_store=False` config flag.

3. **`infer=True` UPDATE behavior** — the v8 spec assumes UPDATE actions exist in the extract pipeline. Phase C must update the v8 spec or pivot the design (e.g., do raw insert + manual semantic-merge if needed). Recommend: do NOT use `infer=True` in sspower; treat blocks as immutable raw memories with caller-side dedup.

4. **Async `add` parity** — read sync `_add_to_vector_store` in detail; async path at line 2070+ skimmed only. Phase C must verify the async path mirrors the same caller-metadata-preservation and ADD-only semantics. Repro: read main.py lines 2070-2300 in detail and diff against sync.

5. **Mem0 import-time side effects beyond telemetry** — `setup_config()` at line 327 and `mem0_dir` os.makedirs at setup.py line 11 run at import. Phase C must verify these don't write outside `MEM0_DIR` or create unintended files in `~/.mem0`. Repro: `MEM0_DIR=/tmp/foo python -c 'import mem0'` and inspect `/tmp/foo` and `~/.mem0`.

6. **Chroma `contains`/`icontains`/`NOT` silent fallback/drop** — `_generate_where_clause` at chroma.py:285-287 silently maps `contains`→`$eq`, and lines 316-318 silently drop `$not`. Unknown — needs upstream issue. sspower must avoid these operators on Chroma backend or add a runtime warning. Phase C verification: write integration test that issues a `contains` query and asserts the wrong (eq-fallback) result is returned, to confirm the silent-fallback is in effect at runtime.
