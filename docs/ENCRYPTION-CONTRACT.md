# ZamBase — Phase 2A.3.2: Data Classification and Cryptographic Contract

> **Design contract for review; not an implementation.** This document defines
> a testable target for Phase 2A.3.3–2A.3.6. No encryption or authorization
> changes are implemented by this document. It does not certify the system for
> government use or establish legal/regulatory compliance.

## Status and decision labels

- **Observed** means verified in the current repository.
- **Contract requirement** means a proposed normative rule for implementation.
  It becomes approved only when the accountable product, security, and
  institutional owners sign off.
- **Provisional** means a recommended baseline that still requires that
  approval.
- **Unresolved gate** means implementation must not make an assumption; resolve
  and record it before the affected Phase 2A.3.3 work.

No evidence of formal stakeholder approval of the architecture choices was
found in the repository. Therefore the technical contract below is
ready for product-owner and security-owner review as a proposal, but is **not
yet an approved cryptographic profile**. Unresolved product and
institutional/legal decisions remain explicit approval gates.

## 1. Verified repository facts

Inspected the Phase 2A.3.1 documents, all tracked Supabase migrations, relevant
RLS and worker RPC definitions, source-record immutability trigger, Python
import/matching workers and their tests, Next.js reconciliation Server Actions
and pages, Docker Compose, and current Python/TypeScript dependency manifests.

- `reconciliation_source_records` contains `source_record_id`, `raw_data`,
  `normalized_data`, and `row_hash`. RLS enables tenant-member reads. Its
  `source_records_immutable` trigger rejects all UPDATE and DELETE operations.
- Its unique index is `(import_job_id, source_record_id, row_hash)`. The active
  import worker canonicalizes JSON with sorted keys and compact separators,
  computes unkeyed SHA-256 over UTF-8 bytes, and chooses `source_record_id`,
  then `id`, then the row number (truncated to 512 characters). Thus identical
  ID/content rows are skipped within one job, while changed content with the
  same ID can coexist; the job ID means this is not cross-job deduplication.
  The separate `imports/loader.py` helper is not the active entry point; it
  uses a different serialization path and derives a missing source ID from a
  row-hash prefix. These differences must not be silently conflated.
- `reconciliation_import_insert_record` currently accepts and persists both
  JSON documents in plaintext. `reconciliation_matching_source_records`
  returns both JSON documents and the source identifier under a run claim and
  lease. `reconciliation_matching_write_candidates` accepts candidate details.
- Import files are uploaded to private Storage as plaintext, then downloaded
  by the import worker to tmpfs through a short-lived claim-bound signed URL.
  The import worker parses each row and currently duplicates it as raw and
  normalized JSON.
- The matching worker loads all source rows for a tenant into a pandas
  DataFrame and calls Splink. It uses a separate database login, scoped RPCs,
  heartbeat, and a fail-closed check before writes when its lease is lost.
- `acceptMatch` reads source `raw_data` and writes plaintext
  `canonical_data`; review, import-detail, entity, and discrepancy pages render
  values in browser responses. `exportEntity` creates plaintext CSV and may
  return it inline. Existing Server Actions use the authenticated Supabase
  client; their authorization is not an adequate replacement for narrowly
  scoped database authorization.
- Existing reconciliation read policies generally allow tenant members to
  read records. The match-candidate update policy includes `member`, although
  UI review actions are gated to `admin`/`owner`. This is a material mismatch.
- A prior migration added pgsodium prototype columns, a table containing raw
  key bytes, and encryption/decryption functions. Later migrations revoke
  application access. Current application paths do not use them. They remain
  disabled and must not be re-enabled.
- Current `requirements.txt` pins Splink, psycopg, httpx, and python-dotenv;
  it does not depend on `cryptography`. The Next.js package manifest does not
  depend on an encryption library. It targets Next.js 15 / Node.js 20 in its
  Dockerfile, and the worker image is Python 3.11.
- Worker DB credentials are distinct. Neither worker should receive
  `service_role` or a database superuser credential. Docker currently uses
  read-only root filesystems, dropped capabilities, and bounded tmpfs.
- Existing job/run lease periods and refresh behavior are implementation
  details, not cryptographic authorization guarantees. Every future decrypt
  must independently validate a current claim and lease.

See [ENCRYPTION-ARCHITECTURE.md](./ENCRYPTION-ARCHITECTURE.md) for the original
assessment and detailed current plaintext flow. These observed findings remain
in force until code and tests demonstrate a change.

## 2. Classification and handling rules

The labels below are **internal handling classes proposed for engineering**,
not legal, government, or regulatory classifications:

- **R1 — Restricted personal:** direct identifiers and personal attributes.
- **R2 — Restricted financial / eligibility:** financial, payment, benefit,
  eligibility, or similarly consequential values.
- **R3 — Restricted linkage:** data that links records or reveals matching,
  identity relationships, or review decisions.
- **R4 — Restricted operational secret:** credentials, tokens, and key
  material.
- **I — Internal metadata:** operational data not intended to be public; assess
  linkability and tenant sensitivity before downgrading.

Treat arbitrary imported JSON and unclassified fields as R1/R2 until explicitly
classified. The organization must determine the actual legal and institutional
classification, purpose limitation, access roles, retention, residency, and
individual rights. Do not infer these from this table.

### 2.1 Field and structure policy

| Field / data category | Internal class | Original recoverable? | Encryption and HMAC policy | Permitted readers and purposes (target) | Retention | Logs, audit, exports, browser |
|---|---|---|---|---|---|---|
| Names and aliases | R1 | Yes only if required for review/correction; otherwise minimize | AEAD required at rest. HMAC is not the default: names are high-variation and normalization/equality may be misleading | Matching service: only configured fields for a live run. Human review: authenticated reviewer role, exact records and fields. Export: only allowlisted purpose/fields | Owner must set source/entity retention and deletion rules; encrypted data does not remove retention duties | Never in logs/audit metadata. Browser only after explicit authorized review. Export only if approved |
| Date of birth | R1 | Yes if matching/review requires it | AEAD required. Exact token only if a specific, approved matching use case and normalization profile exists; no plain SHA-256 | Matching: allowlisted run fields. Review: reviewer role. Export: default deny | Legal/institutional retention unresolved | Never in logs/audit. Browser/export only by approved field policy |
| National identifiers and passport numbers | R1 | Recoverable only where operational/legal need is approved | AEAD required. Exact matching may use tenant/purpose/profile HMAC-SHA-256 token; never unkeyed digest. Keep encrypted original only where recovery is required | Matching token service or run-scoped matcher; human reviewer only where explicitly authorized; no ordinary member read | Specific legal retention/erasure rules unresolved; source immutability cannot override approved deletion obligations | Never in logs/audit/browser by default. Export default deny; explicit approval and field-level audit required |
| Beneficiary, client, account, or source-system identifiers | R1/R3 | Internal database UUID need not be recoverable from source value; source-system value is recoverable only if business requires it | Encrypt source value if recoverable. Prefer opaque internal UUID plus purpose-specific tenant HMAC for exact linking. No plain hash | Import service; matching service under live lease; reviewer only if the task requires the external identifier; export allowlist only | Coordinate source retention and entity-link retention | Never logs/audit. UI displays opaque internal IDs by default; export external identifier only if approved |
| Financial and payment identifiers | R2 | Only if an approved workflow needs exact recovery | AEAD required. HMAC may support exact match with distinct `financial_identifier` purpose and tenant key; do not tokenize credentials, CVV, PIN, or authentication secrets as a substitute for prohibited storage | Import/matching only for approved field allowlist; reviewer only if necessary; export default deny | Data owner/legal decision required, including prohibited fields and retention | Never logs/audit/browser by default; exports require explicit approval |
| Phone numbers | R1 | Usually yes if used for contact or review; product decision | AEAD required. HMAC only for approved exact match after a country-aware canonicalization profile; invalid/ambiguous country means no token | Matching if selected; reviewer if needed; export only approved fields | Data owner decision | No logs/audit. Browser/export only by explicit authorization |
| Addresses | R1 | Yes only if required for review or service delivery | AEAD required. Do not HMAC whole addresses by default; exact tokenization requires a versioned address normalization profile and accepted equality leakage | Matching allowlist; reviewer; limited export | Data owner decision | No logs/audit. Browser/export only approved fields |
| Eligibility, benefit, program, or case details | R2 (may be higher under institutional rules) | Only for a documented operational purpose | AEAD required. HMAC generally not appropriate unless an exact, necessary field is approved | Strictly limited matching/review service and authorized roles. No general tenant-member reads | Must be set by data owner and counsel; not inferred here | Never logs/audit; browser/export default deny |
| `raw_data` | R1/R2 (unknown JSON is restricted) | Yes: source fidelity/review requirement is a product decision | Encrypt whole raw payload with AEAD; never write production plaintext after cutover. No generic raw-JSON HMAC | Import service writes ciphertext; matching decrypts allowlisted fields; reviewer decrypts only explicitly authorized fields | Source retention / deletion decision unresolved | No values in logs/audit. Browser/export default deny except authorized explicit projection |
| `normalized_data` | R1/R2 | Only if normalization is required for repeatable matching or audit | AEAD required. Prefer storing only required normalized values; do not assume duplicate raw data is needed. No whole-record unkeyed hash | Matching allowlist; reviewer only if necessary | Same source policy or separately defined shorter retention | No logs/audit. Browser/export only explicit approved projection |
| `canonical_data` / golden-record values | R1/R2 | Yes for business operation and human review if approved | AEAD required, entity-scoped envelope. Distinct from source DEK | Entity metadata may be visible to approved tenant roles; plaintext fields only to specifically authorized reviewer/export operation | Entity retention, merge, split, and deletion policy unresolved | No values in logs/audit. Browser only for authorized fields; export allowlist |
| `comparison_details` and Splink comparison evidence | R3; may be R1/R2 if values appear | Usually no raw comparison values needed; retain only operational explanation | Minimize to value-free field codes/levels and score. Encrypt any value-bearing details. Never use as unreviewed debug output | Matching service writes minimal details; review role reads approved explanation | Retain with candidate/review record per decision policy | Logs/audit may include allowlisted codes/counts only; browser shows minimized explanation; export default omit |
| Candidate IDs, link IDs, scores, match state | R3 | Yes for adjudication/audit | Keep internal IDs/score only as necessary; avoid raw external identifiers. Not ordinarily field-encrypted, but tenant-scoped and access-controlled | Matching service; review role; tenant role may see status/counts only if approved | Candidate and review retention unresolved | Logs/audit may include opaque IDs, operation and score only if policy approves; browser may show minimized values; export default omit |
| `source_record_id` and `row_hash` | R1/R3 | Source ID: maybe; hash: no user-visible need | Source ID encrypted or represented by opaque ID plus HMAC. Replace new unkeyed SHA-256 row hash with keyed, purpose-separated HMAC if dedup requires it | Import/migration service; matcher receives internal IDs; reviewer access only when needed | Same as source record | No raw source IDs/hash in logs or audit; browser/export omit by default |
| Discrepancy `field_name`, `competing_value`, manual value | R1/R2/R3 | Yes while resolving and maintaining canonical record; not necessarily in audit history | AEAD for competing/manual values; use field registry codes where possible. Do not duplicate values into reviewer state | Reviewer role, exact entity/source relationship, resolution purpose; application must persist decision atomically | Retain unresolved and resolved state per approved decision schedule | Never values in logs/audit. Browser only reviewer; export default deny |
| Evidence and attachments | R1/R2/R3; arbitrary | Per evidence type; may be no | AEAD for content and file payloads; enforce typed schemas, not arbitrary JSON. HMAC only for explicitly indexed identifier fields | Evidence writer service and reviewer role; exact case/decision only | Evidence-specific retention required | No values in logs/audit; browser only authorized review; export default deny |
| Reviewer rationale, `previous_state`, `new_state` | R1/R2/R3 if free text/snapshots include PII | Rationale may need retention; state can often be minimized to codes/IDs | Minimize snapshots; encrypt free text and sensitive state. Do not snapshot decrypted data into audit metadata | Reviewer role and designated audit function, with separate access purpose | Institutional audit/appeal retention decision required | No free text or values in logs/audit. Browser only to appropriately authorized reviewer; export restricted |
| `connection_config` and external source credentials | R4 | Credentials may need use, but not plaintext readback | Never store secret values in general JSON. Use secret-manager references; if unavoidable, encrypt with dedicated secret purpose and separate credential broker | Only connection service identity can retrieve/use. Tenant UI may manage references, not read secret values | Rotate and delete per credential lifecycle | Never logs/audit/browser/export. Audit only secret reference ID, operation, status |
| Import file, `file_ref`, job errors and counts | File R1/R2; path/status I/R3; errors could reveal R1/R2 | Source file may need recovery until import completes/review retention | Encrypt file before durable Storage write. Keep opaque object ref. Persist generic error codes/counts only | Import service via active claim; no tenant direct object read. Job status to authorized tenant roles | Define original-file deletion schedule and failed-job cleanup | No file contents, signed URLs, parser excerpts, tokens. Browser sees status/counts and opaque ref only |
| Run config, blocking rules, comparison field selection | I/R3; may reveal sensitive identifiers | Usually yes for audit/reproducibility but minimize | Allowlist field codes and operations. No field values or arbitrary SQL. Encrypt if institutional threat model requires | Admin/owner configure; matching service reads only the claimed run config | Retain with run audit policy | Logs/audit only config version and approved field codes; browser admin UI only |
| Audit events and metadata | I/R3; can become R1/R2 if callers put values in JSON | Yes for attributable event; avoid copying subject data | No need to encrypt all audit metadata if schema guarantees minimization; encrypt unusually sensitive audit payload separately | Authorized audit readers; database audit writer | Explicit approved policy; current retention defaults/cleanup require environment review | Allowlisted action, tenant, opaque target, purpose, outcome, fields/key version. No PII values, tokens, ciphertext, or key bytes |
| Profiles and Auth identity fields | R1 | Yes for account management | Existing Supabase/Auth storage is outside the proposed reconciliation payload design; classify and protect under separate identity-data design | Authenticated account and company-membership rules as currently defined | Account lifecycle and legal policy unresolved | Avoid propagating profile PII into reconciliation logs/exports |
| Tenant IDs, internal UUIDs, timestamps, status, counts | I; IDs can be linkable | Usually yes operationally | No AEAD by default; tenant scoping, least privilege, and minimization. Never call them anonymous | Tenant roles per data-minimizing UI policy; worker as needed for job | Operational retention policy | Opaque IDs/counts may appear in audit after review; no raw identifiers |
| Database URLs, anon key, claim token, signed URL, KMS identity, DEK/KEK | R4 | Credentials only as needed at runtime; keys never user-recoverable | Secret manager/workload identity; DEKs only in short-lived memory; KEKs external KMS/HSM. Never store plaintext key material in DB/source/image | Only the exact service identity and operation; no human UI retrieval | Rotate/revoke under incident and provider lifecycle | Never logs, audit metadata, exports, browser responses, database rows |

### 2.2 Role baseline (provisional)

Use the existing application roles (`owner`, `admin`, `member`, `viewer`) plus
named non-human identities for the import worker, matching worker, migration
backfill service, crypto broker, and KMS operator. A tenant owner is not a
cryptographic superuser.

- **Viewer/member:** no direct ciphertext/envelope/token access and no
  arbitrary decrypt. They may see only minimized metadata approved by product
  policy.
- **Owner/admin:** may configure sources/runs and perform review/export only
  after a separate field/purpose authorization decision. Existing UI role
  checks alone do not grant decryption authority.
- **Import worker:** encrypts rows only for a valid claimed job; no general
  decrypt, no KMS credentials, no direct sensitive-table access.
- **Matching worker:** decrypts only fields/records in a live claimed run;
  cannot ask for arbitrary ciphertext/company IDs; no general KMS credentials.
- **Backfill service:** one-time, approved scope, resumable, audited; no
  interactive access and no writes to immutable source rows.
- **Crypto broker:** validates actor, tenant, object, purpose, field allowlist
  and lease; alone obtains workload identity to invoke approved KMS operations.
- **KMS operator / disaster-recovery operator:** separate operational identity,
  preferably dual control for destructive or recovery operations; cannot use
  user-facing decrypt routes.

**Unresolved gate:** Approve which existing tenant role may review raw fields,
which may view entity plaintext, and whether `member` may export any sensitive
field. Until decided, plaintext decryption and sensitive exports must be
denied by default.

## 3. Cryptographic contract

The following is a **provisional normative profile** for review. It is not yet
an institutional approval and does not authorize implementation without the
gates in section 10.

### 3.1 AEAD algorithm and library candidates

- Algorithm identifier: `AES-256-GCM`, 256-bit AES key, 96-bit nonce, 128-bit
  authentication tag.
- **Python recommendation:** maintained `cryptography` package:
  `cryptography.hazmat.primitives.ciphers.aead.AESGCM` for bounded record
  payloads; `Cipher(AES, GCM)` for one bounded file message streamed to a
  private temporary file. `cryptography` documents 12-byte nonces, appended
  16-byte tags in the AEAD API, and the critical prohibition on nonce reuse.
- **TypeScript/Node recommendation:** Node.js built-in `node:crypto`
  `createCipheriv` / `createDecipheriv` with `aes-256-gcm`, explicit
  `authTagLength: 16`, and tag handling per Node's API. This is the preferred
  option for the current Node 20 Next.js server; it adds no third-party
  dependency. Any service using it must run on the Node runtime, not an Edge
  runtime.
- **Alternative candidate only:** Web Crypto `SubtleCrypto` AES-GCM can be
  considered for server runtimes if runtime availability and byte/tag behavior
  are validated, but do not perform sensitive encryption/decryption in the
  browser. Do not mix APIs without the cross-language suite.
- Do not add a crypto dependency until implementation approval; pin and review
  versions then. Both candidate runtimes are currently in the repository
  (Python 3.11, Node 20), but the Python package is not currently installed or
  pinned in `requirements.txt`.
- Use maintained library/provider primitives; do not implement AES, GCM,
  GHASH, HMAC, nonce generators, or key wrapping manually. Do not use the
  legacy `pgsodium` functions.

References: [cryptography AEAD documentation](https://cryptography.io/en/latest/hazmat/primitives/aead/),
[Node.js crypto documentation](https://nodejs.org/api/crypto.html),
[NIST SP 800-38D](https://csrc.nist.gov/pubs/sp/800/38/d/final).
NIST has announced a revision of SP 800-38D; review the then-current standard
and KMS/provider constraints before implementation.

### 3.2 DEK and nonce rules

- Generate a fresh 32-byte DEK using the platform CSPRNG (`secrets.token_bytes`
  or a vetted library in Python; `crypto.randomBytes(32)` or
  `crypto.getRandomValues` in Node). Production never accepts a configured
  raw DEK; fixed keys are test-vector-only. Never seed a PRNG from time or IDs.
- Use a dedicated DEK for each encrypted source-file object (one GCM
  invocation for that complete object) and a separate DEK for each bounded
  import-job row-payload scope. The row-payload scope must stay within the
  invocation and byte quotas below; split it into smaller independently
  authorized scopes with fresh DEKs if needed. Use one fresh DEK per canonical
  entity envelope. Use separate purpose keys for tokenization; never derive a
  token key from a DEK or reuse a DEK for another tenant/purpose.
- For every AES-GCM encryption invocation, generate a fresh 12-byte nonce from
  the OS-backed CSPRNG. Nonces need not be secret. Never deterministically
  reuse a nonce after retries, restarts, rewraps, or backfill. Re-encryption
  uses a fresh DEK and nonce; retrying an already committed ciphertext reuses
  that ciphertext rather than encrypting again under the same nonce.
- Persist an encryption-attempt/reservation identity before encryption, and
  atomically commit ciphertext, nonce, envelope reference, and resulting
  attempt state. If the ciphertext insert/transaction fails, mark or retain
  the reservation as consumed and use a newly generated nonce for the next
  encryption attempt. Never keep a nonce in retry state for re-encryption.
  Concurrent workers and restarted workers share the same durable DEK budget;
  they cannot reset counters or assume a failed caller did not encrypt.
- With random nonces, atomically reserve each candidate nonce against the
  envelope/DEK in durable state before encrypting, using a uniqueness
  constraint or equivalent serialized compare-and-reserve. If a collision is
  detected, discard the candidate, generate another, and reserve it. Never
  delete/release a committed nonce reservation, including after a failed
  encryption or database write. The invocation/byte reservation and nonce
  reservation must survive worker restart and transaction retries; otherwise
  random generation alone does not provide a strict no-reuse guarantee.
- Provisional per-DEK hard ceilings are **2^22 (4,194,304) encryption
  invocations**, **2^30 bytes (1 GiB) aggregate plaintext encrypted**, and
  **16 MiB per record message**. For the source-file object, the separate
  **50 MiB plaintext file limit** applies and it is one GCM message; the
  file-object DEK must not also be reused for row payloads. Those row payloads
  use the bounded import-job data scope and its limits. The lower aggregate
  ceiling is intentionally conservative and must be validated against payload
  expansion and throughput before approval. Count every new encryption,
  including retries that create a new ciphertext. A rewrap or reuse of an
  already committed ciphertext is not a new GCM invocation. A failed
  encryption attempt still consumes a reserved invocation and byte budget.
- These are operational limits, **not a proof that GCM is secure up to the
  limit**. GCM security depends on more than invocation count: total processed
  blocks/bytes, nonce uniqueness, message lengths, tag length, number of
  verification attempts, and adversarial access all matter. With uniformly
  random 96-bit nonces, the birthday approximation for a collision after
  `q = 2^22` invocations under one DEK is approximately
  `q(q-1)/2^97`, about `2^-53`. This is a risk estimate, not a guarantee or
  the complete GCM advantage bound. The 1 GiB aggregate cap corresponds to at
  most `2^26` 128-bit plaintext blocks (ignoring per-message length encoding);
  it does not eliminate forgery or multi-user risks. Keep the 128-bit tag,
  reject on any authentication failure, rate-limit and audit verification
  attempts, and do not expose a chosen-ciphertext oracle.
- NIST SP 800-38D section 8 and Appendix B impose construction-specific IV,
  total-processing, and authentication-assurance requirements. In
  particular, §8.3 limits total invocations for the RBG-based IV construction
  to 2^32 under a key across instances, subject to that section's conditions.
  §5.2.1.1 limits plaintext per invocation to 2^39 - 256 bits (about 64 GiB
  less 32 bytes); the proposed record/file limits are far smaller. The
  proposed 2^22 invocation cap is 1,024 times below the cited RBG invocation
  ceiling, but that comparison does not account for every GCM security term.
  Review the selected IV construction, aggregate data, invocation
  distribution, provider/library constraints, and any successor/revised
  SP 800-38D before implementation. Do not treat the standard's maximum as a
  recommended application quota, or the proposed `2^22` cap as sufficient
  security justification on its own.
- Enforce budgets across all concurrent workers using an atomic, durable
  reservation/fencing mechanism scoped to the DEK. Reserve invocation and
  byte budget before encryption; failed/crashed reservations remain consumed
  unless the design can prove no encryption began. Retries and worker restarts
  must not reset counters. Stop before any limit would be crossed and create
  a fresh DEK/envelope for a new bounded scope. Create a new DEK earlier on
  suspected compromise, uncertain nonce history, counter inconsistency,
  scope/purpose change, or a required cryptoperiod/key-policy boundary.
- At the existing one-million-row import cap, two separately encrypted row
  documents per row would require up to two million invocations, but input
  expansion may breach the aggregate byte cap first. Preflight or enforce
  limits while streaming input; abort the import or split it into separately
  authorized bounded scopes rather than extending a DEK's quota.
- **Initial file boundary (50 MiB plaintext maximum):** encryption occurs in a
  trusted server-side ingress/import boundary after authenticated upload
  authorization and before durable Storage persistence. The browser never
  receives the DEK. Stage the bounded plaintext in private, access-restricted
  temporary storage; encrypt the complete file as one AES-GCM message using
  the file's own DEK and fresh nonce; upload only the completed ciphertext
  object to private Storage. Never stream plaintext directly into durable
  Storage or parse an unauthenticated partial decrypt.
- On download, retrieve ciphertext to a private temporary file, authenticate
  and decrypt the complete object, and expose the plaintext file to the parser
  only after the AEAD operation reports successful tag verification. On
  failure, discard parser state, close handles, and remove partial plaintext
  and ciphertext staging files; a startup/periodic cleanup must remove
  abandoned temporary files after crashes. Restrict permissions and ensure
  temporary storage is bounded and isolated. Explicitly measure peak memory:
  the 50 MiB limit is not a claim that current workers can safely buffer it.
- If an upload is not durably committed, a retry is a new encryption attempt
  and uses a fresh nonce; preferably it gets a new envelope/DEK when prior
  nonce history is uncertain. If the complete ciphertext and metadata were
  committed and verified, an idempotent retry may reuse that exact object and
  envelope without re-encrypting. Never re-encrypt under a previously used
  nonce. Partial/uncommitted encrypted objects are not resumable ciphertext;
  delete/quarantine them and restart within the retry policy.
- This initial whole-message boundary is not resumable and larger-file
  streaming is a separately reviewed future capability. Custom chunked GCM,
  including ad-hoc per-chunk nonce/AAD schemes, is prohibited. A larger or
  resumable design must select a maintained streaming-AEAD format/library,
  analyze ordering/truncation/replay/finalization semantics, demonstrate
  Python/TypeScript interoperability where required, and obtain a new review.
- Document any change to these bounds with a GCM usage analysis and renewed
  security review. Enforce message and aggregate-byte bounds in code and test
  them; do not silently truncate or downgrade.

### 3.3 Tag handling and ciphertext format

Record the tag length as exactly 16 bytes. The interoperable AEAD output is
`ciphertext || tag`. Python `AESGCM` already returns this representation;
Node's `Cipher` API returns ciphertext separately from `getAuthTag()`, so
serialization must append the 16-byte tag to the ciphertext. On decrypt, split
the final 16 bytes and pass them explicitly to Node's decipher API.

Database storage uses separate typed columns:

- `algorithm` fixed to the allowlisted value `AES-256-GCM`;
- `format_version` (integer, starts at 1);
- `nonce` (exactly 12 bytes);
- `ciphertext_and_tag` (tag appended, minimum 16 bytes);
- `aad_version`;
- `envelope_id` and opaque object/field references.

For JSON service boundaries only, use:

```json
{
  "format": "zambase.aes-256-gcm.v1",
  "nonce_b64url": "<unpadded base64url of exactly 12 bytes>",
  "ciphertext_and_tag_b64url": "<unpadded base64url, final 16 bytes are tag>"
}
```

Reject unknown formats, unknown algorithms, padding/non-canonical encodings,
wrong lengths, extra fields where a strict schema is expected, and oversized
payloads. Database metadata is not accepted from an untrusted caller as
authority for what to decrypt.

### 3.4 Canonical associated data

Associated data authenticates context but is not encrypted. Version 1 uses a
binary, unambiguous length-prefixed tuple; do not rely on JSON property order,
locale formatting, string concatenation with delimiters, or database JSON
serialization.

Exact encoding:

1. ASCII magic bytes `ZBAA` (4 bytes).
2. Unsigned 16-bit big-endian AAD version `1`.
3. Seven fields in this exact order. For each field append an unsigned 32-bit
   big-endian byte length followed by the field's strict UTF-8 bytes:
   `tenant_uuid`, `object_type`, `object_uuid`, `field_code`, `purpose`,
   `envelope_uuid`, `payload_format`.
4. UUIDs are canonical lowercase ASCII UUID strings with hyphens. Enum/code
   values are lowercase ASCII from server-side allowlists. No null or empty
   field is permitted. Payload format is the exact constant
   `zambase.aes-256-gcm.v1`.

The caller supplies only the logical object reference. The trusted database
authorization/broker derives tenant and field/purpose from authoritative
records and an allowlist, then builds AAD. AAD is not a substitute for that
authorization. Do not put user data, source identifiers, or PII in AAD or
provider encryption context.

### 3.5 Envelope metadata and KMS contract

Persist no production plaintext KEK or DEK. An envelope records:

- opaque envelope UUID, tenant UUID, scope type/UUID, purpose, lifecycle state;
- provider name, immutable KEK resource/key ID, exact key version/generation;
- wrapping format/algorithm version, wrapped DEK bytes, and non-sensitive
  provider metadata;
- AEAD format and AAD version supported by this envelope;
- created/activated/retired timestamps and replacement reference;
- invocation/byte budget counters sufficient to enforce key limits.

KMS interface (logical operations; provider adapters map to AWS KMS, Google
Cloud KMS, Azure Key Vault, OpenBao Transit, or an institution HSM):

| Operation | Required contract |
|---|---|
| `generate_dek(scope, purpose)` | Broker obtains 32 random bytes from an approved CSPRNG, creates envelope metadata, wraps the DEK under the configured KEK, persists only wrapped material, and makes the plaintext DEK available only inside the authorized in-memory crypto operation |
| `wrap_dek(dek, immutable_context, key_ref)` | Accept exactly 32 bytes and approved context; return wrapped bytes plus provider/key ID/version/wrapping format. Never log the input or output |
| `unwrap_dek(envelope, expected_context, authorized_operation)` | Broker verifies envelope ownership, tenant, scope, purpose, key ID/version, caller, fields, operation and lease before KMS. Reject any context or version mismatch. Do not offer arbitrary ciphertext/tenant parameters |
| `get_key_metadata(key_ref, version)` | Return provider, key/version state, algorithm, and lifecycle metadata; no key bytes |
| `rewrap_dek(envelope, old_version, new_version, context)` | Rewrap the same DEK only for KEK rotation; verify new unwrap and atomically activate replacement metadata |
| `rotate_key(key_ref)` | Provider-specific controlled rotation; operation is auditable and never implies old versions are disposable |

Use provider-native authenticated encryption context where supported. For a
provider wrapping API without context binding, bind to immutable envelope
metadata in the trusted broker and rely on payload AEAD AAD to reject
substitution; that adapter must pass dedicated swap/tamper tests. Production
uses workload identity, not long-lived credentials in worker env. Workers
never receive general KMS credentials or arbitrary decrypt capabilities.

#### Broker execution model

| Model | Trust implications | Performance and operational implications | Contract |
|---|---|---|---|
| **A. Broker performs AEAD** | DEKs and plaintext stay inside the broker boundary. This minimizes worker compromise exposure and centralizes authorization/audit, but makes the broker a high-value plaintext-processing service and potential availability bottleneck. | Adds network and broker CPU/throughput load; large payload transfer may dominate. Requires capacity limits, backpressure, bounded request sizes, and broker availability/lease coordination. | **Preferred for human review, entity viewing, discrepancy resolution, and export.** Broker returns only the authorized projection or a bounded authenticated result to the requesting server action; never a DEK. |
| **B. Narrow temporary DEK handoff** | Matching worker can access the DEK and plaintext for its authorized scope. A compromised worker or memory dump can expose that scope, including fields already decrypted. It remains a centralized cross-tenant trust boundary. | Avoids relaying large datasets through broker AEAD and can keep Splink data local to the worker, but still requires broker authorization, KMS access, secure authenticated handoff, lease fencing, and end-to-end memory/capacity controls. | Allowed only when matching cannot practically use model A. Handoff is authenticated, short-lived, bound to one run claim, tenant, explicit field allowlist, purpose `matching`, envelope/scope, and expiration no later than the lease. It cannot unwrap other envelopes or select arbitrary fields. |

For model B, the broker validates the current run claim and lease before KMS
unwrap, then issues a one-operation capability scoped to the listed records
and field codes. The worker revalidates the lease before every bounded
decryption batch and immediately before candidate writes. The capability
expires on lease expiry/reassignment and cannot be renewed without a fresh
broker authorization. On any lease loss, stop decrypting, cancel work where
possible, discard in-memory results, and write no candidates. Keep the DEK
only in process memory for the shortest batch; never persist, log, cache
across runs, or send it to Splink as configuration. Document that reliable
zeroization of Python/pandas/DuckDB memory cannot be guaranteed.

A DEK handoff is **not cryptographically restricted to the listed fields**:
any holder can attempt to decrypt any ciphertext under that DEK if it can
obtain the ciphertext and construct the AAD. Therefore model B is allowed only
when the DEK's entire ciphertext scope is no broader than the exact records
and fields authorized for that run, or when the residual wider access is
explicitly accepted and independently contained. If the current import/job
DEK spans unrelated records or fields, do not hand that DEK to matching; use
broker-performed AEAD or a separately designed run-scoped ciphertext/key
boundary. Broker-side authorization logs and an expiring handoff do not
eliminate this residual key-holder capability.

#### Development and production provider separation

- Local development may use a clearly named local-only adapter for synthetic
  data and automated tests. It may keep an ephemeral test key outside the
  repository with restrictive filesystem permissions; it must never read,
  import, or reuse production keys or credentials. Prefer disposable keys
  created for each test run.
- Local key files and this adapter are not KMS/HSM-equivalent and must never
  be represented as production-grade key protection. Do not use this mode with
  real tenant data.
- Provider mode is explicit and validated against deployment identity.
  Staging and production startup must fail if the local/test adapter is
  selected, if the environment identity is missing/ambiguous, or if an
  approved production provider/key reference/workload identity is unavailable.
  Do not default an unset provider to local mode outside an explicitly
  isolated developer/test profile; no fallback is permitted.
- The production provider and operating region, key ownership, workload
  identity, recovery and availability objectives remain approval gates.

### 3.6 Failure behavior and storage design

- Fail closed on missing/disabled/unavailable provider, unknown key version,
  missing envelope, invalid authorization, lost lease, KMS timeout, nonce/key
  metadata mismatch, malformed data, or tag/AAD failure.
- No plaintext fallback, local-key fallback, silent defaults, or
  success-shaped error. Return a generic external error; internally record a
  non-sensitive error code and request ID.
- **Authorization/audit/release ordering:** (1) authenticate actor/service
  and derive tenant from trusted identity/job; validate object, field
  allowlist, purpose, operation, status, and current lease without asking KMS;
  (2) commit a sanitized `decrypt_attempt_authorized` audit event before KMS;
  (3) unwrap through the broker, decrypt and authenticate tag/AAD into a
  protected buffer; (4) recheck authorization, record state, and lease; (5)
  commit a distinct `plaintext_release_authorized`/successful-sensitive-read
  audit event; (6) only after that commit may plaintext be returned to the
  authorized caller. If either required audit commit fails, fail closed and
  discard plaintext. The success event means an authorized plaintext release
  was prepared; it cannot prove that a network client received every byte.
- Record failed KMS/decrypt/authentication outcomes separately as
  `decrypt_failed` with non-sensitive reason codes, without overwriting the
  attempt event. Denied authorization may be recorded as
  `decrypt_denied` under the audit policy but never reaches KMS. Do not mark
  an attempt as a successful read merely because authorization passed.
- All audit records omit plaintext, ciphertext, HMAC tokens, signed URLs,
  key bytes, and source-derived exception details. Return a generic
  non-sensitive error plus correlation ID externally; internally retain only
  allowlisted error codes. Never use a plaintext fallback or success-shaped
  response. If failure-audit storage is unavailable, still withhold plaintext
  and surface an operational alert through an independent safe channel.
- Zeroize mutable buffers where the runtime/library permits, but do not claim
  reliable zeroization of Python/JavaScript immutable strings, garbage-collected
  heaps, pandas, or DuckDB. Minimize copies and worker lifetime.
- Proposed sidecar ownership: non-login database owner role; no direct SELECT,
  INSERT, UPDATE, or DELETE to `anon`, `authenticated`, `service_role`, worker
  logins, or `PUBLIC`. RLS enabled and forced as defense in depth. Expose only
  operation-specific RPCs with fixed signatures and derived tenant context.
  Migrations remain administrator-controlled.

## 4. Python / TypeScript interoperability contract

Python `cryptography` AESGCM and Node `node:crypto` AES-256-GCM implement the
same NIST AES-GCM primitive and can interoperate with the specified key, nonce,
AAD, tag length, and byte order. No language-specific serialization is allowed
inside ciphertext. Current code targets Node 20 and Python 3.11; package/runtime
versions must be pinned and checked when implementation begins.

Required shared fixtures are version-controlled, synthetic, and contain no
real tenant data:

1. NIST AES-256-GCM known-answer vectors, including empty plaintext and
   non-empty plaintext/AAD.
2. Python encrypt -> Node decrypt and Node encrypt -> Python decrypt, asserting
   exact plaintext bytes and exact canonical AAD bytes.
3. Both runtimes serialize exactly 12 nonce bytes and `ciphertext || 16-byte
   tag`; JSON base64url has no padding and round-trips strictly.
4. UTF-8 edge fixtures (NFC text, supplementary-plane character, empty payload
   where schema permits) are encrypted as exact byte sequences; no implicit
   JSON or Unicode normalization occurs in the AEAD layer.
5. Same key/plaintext/nonce/AAD test fixture gives same bytes in both runtimes;
   production must never reuse the fixture nonce.
6. Cross-runtime rejection for modified ciphertext, tag, nonce, AAD bytes,
   AAD version, format version, or wrong key.
7. File test at 50 MiB verifies authenticated output and that no decrypted
   bytes are parsed/released before final tag verification.

NIST vector sources: [NIST SP 800-38A/38D publications](https://csrc.nist.gov/projects/cryptographic-standards-and-guidelines/example-values),
[NIST SP 800-38D](https://csrc.nist.gov/pubs/sp/800/38/d/final).
Use official vectors in test code rather than inventing expected ciphertext.

## 5. HMAC exact-matching contract

- Algorithm: full 32-byte **HMAC-SHA-256** output; compare using constant-time
  comparison in the trusted application/service where equality is not delegated
  to a database index. An indexed exact lookup may compare fixed-width tokens
  in PostgreSQL; do not expose a token-verification oracle to clients.
- Token keys are independent random 32-byte secret keys per tenant, token
  purpose, and version, protected/wrapped by the KMS. Never derive them from
  DEKs, KEKs, database IDs, or public salts. HMAC secret material never enters
  PostgreSQL in plaintext.
- HMAC input is a canonical binary tuple: ASCII magic `ZBHM` (4 bytes),
  unsigned 16-bit big-endian version `1`, then six fields in this exact order:
  `tenant_uuid`, `token_purpose`, `identifier_type`,
  `normalization_profile_id`, `normalization_version`, and normalized
  identifier bytes. Each field is encoded as unsigned 32-bit big-endian byte
  length followed by its bytes. The first five fields are strict UTF-8
  canonical lowercase ASCII UUID/allowlisted enum values; the final field is
  the exact normalized UTF-8 byte sequence from the named profile. No null or
  empty fields are permitted. This provides domain separation and prevents
  equal values in different tenants/purposes from producing the same token.
- Token metadata records tenant, identifier type, purpose, profile/version,
  HMAC algorithm, token-key ID/version, and full token bytes. Tokens must not
  be returned in browser responses, logs, audit metadata, or exports.

### 5.1 Normalization rules

There is **no generic "strip punctuation and lowercase" identifier
normalizer**. Before enabling a field for tokenization, add a reviewed,
versioned profile for its issuing jurisdiction/system and semantics:

- Decode strict valid Unicode; reject invalid encodings, controls, and
  unsupported characters. Unicode NFC may be applied only when the profile
  explicitly says canonically equivalent forms identify the same value.
- Do not apply Unicode NFKC, case folding, transliteration, punctuation
  removal, whitespace collapse, or numeric coercion globally.
- Numeric identifiers are strings, never numbers: preserve leading zeros.
  Convert accepted Unicode digits to ASCII only when that identifier's
  authoritative profile explicitly permits it; otherwise reject.
- Country/issuer prefixes, check digits, separator removal, phone country
  codes, date formats/time zones, and case sensitivity are profile-specific.
  Ambiguous or invalid input produces no token and a generic validation
  outcome; it is not coerced into a potentially colliding value.
- Missing, null, empty, whitespace-only, malformed, or invalid identifiers
  produce **no token**. Do not use a shared sentinel token for missing values.
- Names, addresses, fuzzy fields, and free text are not tokenized by default.
  They remain encrypted and may be used for fuzzy matching only after
  field-specific authorization and normalization review.

### 5.2 Versioning, lookup, and leakage

- Store `token_version` and `normalization_version` independently. They identify
  HMAC key generation and canonicalization semantics respectively.
- During rotation, issue tokens under the new key and version while retaining
  the old version. Backfill from authorized plaintext/decryption, verify
  counts, query both explicit versions, and never compare a v1 token directly
  with a v2 token. Cut old-version writes only after all active rows and
  recovery backups are accounted for.
- A compromised token key requires retiring the version and regenerating
  tokens from protected source data. HMAC tokens cannot be "rekeyed" without
  the normalized original value.
- Tokens reveal equality and frequency within the same tenant/purpose/profile
  and allow linkage across datasets that share that scope. If the secret key is
  compromised, low-entropy IDs can be tested offline. Separate tenant and
  purpose keys reduce cross-scope linking but do not eliminate these risks.
- HMAC tokens enable exact equality only. They are not encryption, cannot be
  reversed without guessing, and do not support edit-distance/fuzzy matching.

### 5.3 Source identifiers and row-fingerprint migration

**Observed semantics:** the current active worker hashes compact, sorted-key
JSON encoded as UTF-8 with unkeyed SHA-256. It chooses the record's
`source_record_id`, else `id`, else the one-based row number; truncates the
selected string to 512 characters; and inserts through a claim-scoped RPC.
The database's unique key `(import_job_id, source_record_id, row_hash)` makes
an identical source ID and row hash idempotent within one job. Different
content under the same ID is allowed, as is the same row in another job.
Rows are immutable. These are existing semantics, not an endorsement of the
unkeyed hash. SHA-256 row hashes reveal equality and can be vulnerable to
offline guessing for predictable/low-entropy rows.

**Proposed replacement:** use a dedicated tenant-scoped HMAC-SHA-256 purpose
`row_fingerprint`, keyed independently of encryption and identifier-match
tokens. The canonicalization profile must be versioned and reproduce the
active worker's accepted record serialization semantics before the importer
switches. The HMAC message binds tenant, import job, source ID, canonicalizer
ID/version, and canonical row bytes using a versioned length-prefixed tuple.
Use the full 32-byte HMAC. Keep fingerprint, key version, and profile version
in a restricted sidecar; no plaintext row is stored in the fingerprint
sidecar. This retains the current same-job duplicate scope without enabling
cross-job equality unless explicitly designed.

Where `source_record_id` itself is classified sensitive, represent it for new
lookup/matching purposes with a tenant- and data-source-scoped HMAC token under
a distinct `source_record_identity` purpose, plus an opaque internal source
row UUID. Define a profile that preserves the current string semantics (no
numeric conversion or loss of leading zeros); do not apply a generic
normalizer. Keep the historical plaintext ID unchanged on immutable rows
during migration. This token is not the row fingerprint: it identifies the
same external source identifier across rows, while the row fingerprint
distinguishes content versions.

**Additive transition; no source-row rewrite:**

1. Add versioned fingerprint and, where classified, source-ID-token sidecars
   keyed to the immutable source-row UUID and import job/data source. Leave
   every historical `row_hash`, source ID, row, and existing unique index
   unchanged. Backfill HMAC fingerprints/tokens from authorized source
   payloads and bind each to its original source-row UUID.
2. Shadow-compute the HMAC on imports while the current insert path remains
   authoritative. Compare counts and duplicate decisions using synthetic
   fixtures and controlled data; never log row content or fingerprints.
3. Before allowing any writer to store HMAC-based identity, stop or gate
   legacy writers and ensure a compatible importer/RPC handles both legacy
   fingerprints and versioned HMAC sidecars. During key-version overlap,
   calculate/lookup all still-supported versions, but write only the active
   version. Re-imports must map to the existing immutable source-row UUID and
   return a duplicate result rather than creating a second row.
4. Preserve historical rows by UUID and their original SHA hash. Never
   replace old hashes or update immutable source rows to HMAC values. Any
   later removal of the legacy hash column/index is a separate reviewed
   migration after every required reader, re-import path, retention policy,
   and backup/recovery path supports the versioned sidecar.
5. Test same-job exact duplicates, changed row content with same source ID,
   repeated rows across separate jobs, absent IDs/row-number fallback,
   canonicalization compatibility, historical hash lookup, interrupted
   backfill, and mixed-version key rotation. Do not silently change the
   current ID fallback or cross-job dedup behavior as part of cryptography
   work.

Key rotation must retain old fingerprint versions while retained historical
rows or backups need them. To compute a new version, obtain the source row
through an authorized decrypt/backfill path; a fingerprint cannot be
re-keyed from the old HMAC alone. Keep old/new version lookup explicit until
coverage and restore evidence permit retiring the old version.
The same applies to source-ID tokens: retain historical rows and their opaque
UUID mapping, issue new token versions during overlap, and only retire the
old HMAC key after all retained lookup needs and backups are accounted for.

## 6. Authorization contracts

All checks are enforced at a trusted server/database boundary, not just in
React UI code. The tenant is derived from a verified membership or active job
record, never trusted from a caller's company ID. Ciphertext and wrapped-DEK
references are not bearer capabilities. No public/generic
`decrypt(ciphertext, company_id)` or KMS proxy is allowed.

| Operation | Actor and tenant binding | Object / field / purpose checks | Lease / role checks and output |
|---|---|---|---|
| Import encryption | `reconciliation_import_worker` identity; tenant and source derived from active claimed import job | Only that job's uploaded file and validated import schema; purpose fixed to import/source ingest; import service may encrypt but not read existing plaintext | Verify unexpired job claim at claim, before encryption, and before each bounded insert. No KMS credentials in worker. Persist ciphertext and wrapped envelope through fixed RPC; return only counts/status |
| Import-file encryption | Trusted upload/ingress service, with authenticated uploader identity and tenant/data-source membership | Fixed bucket/object path derived server-side; purpose `import_file`; no user-supplied KMS key or object path | Authorize source upload, size/type limits, one-time object/job binding. Storage receives ciphertext only. Browser never receives DEK |
| Import backfill | Dedicated non-login-triggered backfill service identity, approved migration run | Enumerated immutable source IDs and exact `raw_data`/`normalized_data` fields; fixed purpose `backfill`; no client-selected ciphertext or tenant | Job scope/tenant derived from locked migration task; batch lease; read through privileged audited migration path; insert sidecars only. Never UPDATE source rows |
| Matching decryption | Matching service identity with valid claimed run | Tenant/source set derived by run; field codes must be in run's reviewed allowlist; purpose fixed to `matching`; only source records eligible for that run | Check lease before records, before KMS, after decrypt, and immediately before candidate write. On loss, refuse new decrypts and discard results; no general KMS identity in worker |
| Human review decryption | Verified user JWT / server identity | Tenant membership and specific candidate/entity/source relationship; only field codes required by selected review action; purpose `review`; source and entity status checked live | Provisional reviewer authorization: existing owner/admin only pending product approval. Member/viewer get no plaintext. Return only requested projection to authenticated response; emit sensitive-read audit before release |
| Entity viewing | Verified user membership | Distinguish metadata from canonical values; tenant and entity relation authoritative; requested canonical fields allowlisted; purpose `entity_view` | Metadata roles and plaintext roles separately configured. Until approved, show opaque/minimized metadata and deny canonical plaintext. No client table read of ciphertext/envelopes |
| Discrepancy resolution | Verified reviewer identity | Exact unresolved discrepancy, entity/source relation, field allowlist, purpose `discrepancy_resolution`; submitted correction validated by typed field schema | Owner/admin provisional, not approved. One transaction records decision, updates canonical state, and audit metadata without values. Reject cross-tenant source IDs or stale resolution state |
| Export | Verified user JWT / server action | Tenant/entity relation, export field allowlist, purpose `export`, format and row/size bounds. Do not accept arbitrary column names | Provisional owner/admin/member policy unresolved; default deny sensitive fields. Audit before plaintext release. No inline unrestricted CSV or persistent shared export object by default |
| Key rotation / rewrap | Dedicated KMS operator/workload identity | Exact provider key reference, envelope IDs, old/new versions and approved tenant/scope; purpose `key_rotation` | Two-person approval for destructive disable/delete; no data plaintext returned. Rewrap only existing DEKs; verify before atomic activation |
| Disaster recovery | Separate recovery identity and approved incident/change record | Restored snapshot, exact KMS versions, defined tenant/scope and restore purpose; no user-supplied arbitrary ciphertext | Dual control/break-glass approval, isolated restore, immutable audit trail, no ordinary production worker. Release service only after decrypt/count/integrity checks and access review |

**Required broker invariant:** authorization must happen before KMS unwrap and
be rechecked against authoritative state immediately before plaintext release.
RLS on a ciphertext table alone is insufficient. A member must not be able to
take a visible ciphertext ID, wrapped DEK ID, tenant UUID, or changed purpose
and obtain plaintext.

**Audit invariant:** sensitive read/decrypt event records actor/service,
tenant, opaque object/scope ID, purpose, operation, approved field codes,
key-version reference, request/run ID, outcome, and time. No plaintext,
ciphertext, token, signed URL, key bytes, or exception text containing values.
If the audit commit is required and fails, no plaintext is released.

## 7. Migration, database access, rollback, and recovery contract

### 7.1 Sidecar ownership and RLS

- Keep `reconciliation_source_records` immutable. Backfill never updates,
  deletes, or replaces source rows or their JSON columns.
- Ciphertext payloads and envelopes are sidecar records tied by foreign keys to
  tenant and logical object. Database constraints/RPCs verify that the
  referenced source/entity belongs to the same `company_id`; do not accept a
  caller's tenant value as proof.
- Use a dedicated NOLOGIN owner and private schema/table ACLs. Enable and
  force RLS on exposed tables, but do not grant direct table access to
  `anon`, `authenticated`, `service_role`, import/matching workers, or `PUBLIC`.
  Security-definer wrappers have empty `search_path`, fixed ownership,
  qualified references, narrow signatures, explicit `REVOKE`/`GRANT`, and
  tenant/object/operation checks.
- Worker roles retain job/run-specific capabilities only. Do not grant
  broad schema/table access or KMS permissions to them. Never weaken existing
  RLS, lease validation, source immutability, or audit ACLs.
- HMAC token tables expose no tokens to browsers. Matching equality lookup is
  a fixed server-side operation; no arbitrary client query or verification
  oracle.

### 7.2 Backfill, dual read/write, and rollback

1. Add sidecar schema and RPCs additively. A source-record insert transaction
   may create the immutable source row plus encrypted sidecar in one
   transaction while existing plaintext is temporarily retained for
   compatibility. Clearly mark the plaintext state; do not call this
   ciphertext-only.
2. Backfill by stable source/entity ID and field. A unique logical key
   `(tenant, object_type, object_id, field_code, payload_version)` plus a
   migration task ID makes the insert idempotent. Persist state/counts, not
   plaintext samples or raw errors. On retry, first check whether a verified
   ciphertext exists; never reuse an old nonce for a new encryption attempt.
3. Verify decrypt/AAD, coverage/counts, tenant links, and authentication before
   marking a scope `verified`. Failed or partial work remains visible and
   blocks cutover.
4. Dual-read is temporary and versioned: verified ciphertext is preferred;
   plaintext fallback is allowed only for explicitly enabled legacy scopes
   and is measured/audited. Unknown/missing ciphertext must not silently
   downgrade.
5. Dual-write is a short migration-only state. It increases plaintext copies
   and must have an approved end date, authorized writer, and auditable
   counters. Source rows still insert only once and remain immutable. Stop
   dual-write only when all new records create verified ciphertext sidecars.
6. Ciphertext-only writes then place no sensitive source value in `raw_data`,
   `normalized_data`, canonical JSON, or other legacy plaintext columns. For
   existing NOT NULL source columns, the implementation must first define
   non-sensitive placeholders and prove every active reader is upgraded.
   Never write a fake value that is mistaken for valid data.
7. Rollback during transition means reverting to a compatibility release that
   understands the same sidecar format. Do not roll back to code that only
   reads plaintext after any ciphertext-only data exists. Preserve all
   ciphertext, envelopes, key versions, and migration state. No destructive
   reverse migration.
8. Retire plaintext only in a later separately reviewed release, after
   retention/legal approval, complete coverage, access-control testing,
   successful backup restore, rollback-window expiry, and written approval.

### 7.3 Backup, outages, and key recovery

- A restorable backup includes ciphertext, nonce/tag, AAD/format versions,
  wrapped DEKs, provider/key IDs and versions, token versions, object links,
  and migration state. Back up or retain external KMS/HSM key versions and
  access policies for at least as long as any retained ciphertext/backup.
- A database backup without recoverable external keys is a potential
  unrecoverable data-loss event. A KMS key without matching database metadata
  and ciphertext is not a recovery.
- Test isolated full restore, KMS outage, disabled/deleted KEK, provider
  account loss, regional recovery, compromised DEK, and compromised HMAC key.
  The expected behavior during a provider outage is fail closed, not fallback
  to plaintext or a local key.
- KEK rotation: create/enable new KMS version, rewrap existing DEKs in bounded
  batches, unwrap/verify with the new version, atomically activate new
  envelope metadata, retain old versions for backup recovery. Rewrapping does
  not remediate a compromised DEK.
- DEK rotation: generate new independent DEK, decrypt and re-encrypt each
  scope with fresh nonce and identical expected AAD semantics (new envelope
  version recorded), verify, switch the active sidecar pointer, and retain old
  ciphertext until rollback/recovery gate passes.
- HMAC rotation is distinct: generate next token-key version; backfill tokens
  from authorized originals; query old/new versions explicitly during overlap;
  verify coverage and restore; then stop old writes and retire old tokens/key
  only after retention approval.
- Disaster recovery requires an isolated environment, named recovery identity,
  change/incident approval, dual control for key restoration where feasible,
  access/audit review, and successful integrity/count/decrypt checks before
  restored services serve users.

## 8. Staged acceptance test plan

These are requirements, not claims that tests have been implemented or run.
All tests use synthetic data. They are grouped by subsystem and execution
stage:

- **Can be prepared before implementation:** review and freeze standards-based
  expected vectors and AAD/HMAC fixtures for C01, C03, and C16; review
  normalization/domain-separation cases for C17-C18; confirm proposed
  configured limits and boundary cases for C09. Those fixtures/spec checks
  can be checked independently now, but runtime pass/fail for implemented
  crypto still requires the corresponding code.
- **Component tests:** implement alongside each primitive, schema, broker,
  worker, or migration. They gate that component's acceptance, not the start
  of its development.
- **Feature activation/cutover tests:** integration, restore, and workflow
  tests run only after the required components exist; they gate enabling
  sensitive paths, tenant rollout, or plaintext retirement. They are not
  prerequisites to begin Phase 2A.3.3.

### 8.1 Cryptographic primitive and interoperability

| ID | Test | Expected outcome |
|---|---|---|
| C01 | Python and TypeScript run official AES-256-GCM known-answer vectors | Both match published ciphertext/tag exactly |
| C02 | Python encrypt / Node decrypt, and Node encrypt / Python decrypt with same key, nonce, AAD | Exact original bytes recovered in both directions |
| C03 | Binary AAD v1 fixtures, including field order, UTF-8 byte lengths, UUID canonical form, and enum validation | Both runtimes produce byte-for-byte identical AAD; malformed/noncanonical input rejected |
| C04 | Strict JSON/base64url serialization round trip | Exact 12-byte nonce and ciphertext||tag recovered; padding, malformed, extra/unknown fields rejected |
| C05 | Flip one bit independently in ciphertext, tag, nonce, key, AAD tenant, object, field, purpose, envelope, or format version | Authentication/format failure; no plaintext released |
| C06 | Substitute tenant A ciphertext/envelope/payload reference into tenant B object | Authorization rejects before KMS or AEAD; if forced to crypto layer, AAD/tag validation rejects |
| C07 | Substitute ciphertext between two fields or purposes within one tenant | Decrypt denied by allowlist and AEAD AAD authentication |
| C08 | Repeat encryption with production CSPRNG across parallel workers/restarts and inspect nonce ledger/test instrumentation | No nonce reuse for a DEK; counter cap enforced; cap exhaustion stops writes and requires new DEK |
| C09 | Attempt to exceed per-message, per-file, invocation-count, and aggregate-byte limits | Request fails closed before over-limit encryption/decryption; no partial successful write |
| C16 | HMAC RFC 4231 known-answer vector plus application domain-separation fixtures | Full HMAC-SHA-256 bytes exactly match expected values |
| C17 | Same identifier and profile in same tenant/purpose/version; vary tenant, purpose, identifier type, normalization version, and key version | Only same complete scope yields equal token; every cross-scope token differs |
| C18 | HMAC normalization profiles for leading-zero IDs, Unicode NFC edge cases, case-sensitive values, phone country ambiguity, invalid/missing values | Profile fixtures are deterministic; leading zeros preserved; ambiguous/invalid/missing produce no token; no generic coercion |

### 8.2 Database and authorization

| ID | Test | Expected outcome |
|---|---|---|
| C10 | Worker/user supplies arbitrary ciphertext, company ID, object ID, field code, purpose, or envelope ID | Broker/RPC rejects; no plaintext or DEK returned |
| C11 | Anonymous, non-member, viewer, member, admin, and owner matrix for each decrypt/export operation | Only signed-off role/purpose combinations succeed; all other roles denied at trusted boundary, not merely hidden UI |
| C12 | Expired, missing, stale, replayed, replaced, and tenant-mismatched import/matching lease | No unwrap/decrypt; no further source read, candidate write, or finish accepted |
| C13 | Lose lease during an active match/decrypt | New decrypts stop; process output is discarded; no candidates are committed after loss |
| C14 | KMS missing config, local provider in staging/production, timeout, denied identity, disabled key, wrong key version, malformed wrapped DEK | Startup/operation fails closed; no local/plaintext fallback; safe non-sensitive error and audit outcome |
| C15 | Audit event sink unavailable for a required sensitive read | Plaintext release is aborted; no success-shaped response |
| C20 | Unauthorized review/export request asks for a permitted record but forbidden field or purpose | Request denied; no plaintext in response, logs, or audit metadata |
| C21 | Sidecar insert with wrong company/object FK; same-job same-ID/same-content retry; same-ID changed-content row; and identical row in another job | Tenant mismatch rejected; current dedup scope is preserved, retries are idempotent within a job, cross-job behavior is unchanged, and original immutable rows stay unchanged |
| C26 | RLS/ACL review of envelopes, ciphertext and token tables as `anon`, `authenticated`, service role, import worker, matching worker, and public | Direct table access denied; only audited narrow RPCs work for explicitly authorized operation |
| C27 | Source immutability trigger and grants during backfill/cutover | UPDATE/DELETE still fail; backfill uses only sidecar insert/state transitions |

### 8.3 Migration and recovery

| ID | Test | Expected outcome |
|---|---|---|
| C19 | HMAC identifier/source-ID/row-fingerprint key rotation and normalization-profile version transition | Old/new versions are independently queryable; historical UUID mappings remain identifiable; no cross-version direct comparison; backfill counts verified before old-version retirement |
| C22 | Interrupt backfill after each stage and retry same task | Resumes without duplicate logical payload, plaintext mutation, nonce reuse, or lost progress |
| C23 | Corrupt ciphertext, missing envelope, missing old KMS version, count mismatch during backfill | Scope remains failed/incomplete; cutover blocked; source plaintext remains untouched |
| C24 | Dual-read with verified ciphertext, legacy-only scope, corrupt ciphertext, missing ciphertext, and disabled fallback | Ciphertext is preferred; only approved legacy scope may fallback and is audited; corrupt/missing data never silently downgrades |
| C25 | Ciphertext-only new write, then application rollback simulation | Compatible release still reads it; old plaintext-only release is explicitly prevented from deployment |
| C28 | KEK rewrap, old/new provider versions, failure half-way through batch | New wraps verified before activation; retries idempotent; old versions retained; no data plaintext change |
| C29 | DEK rotation and HMAC rotation under normal and interrupted operation | New version verified before active switch; no lost decryptability; compromised DEK triggers data re-encryption, not just rewrap |
| C30 | Full backup restore into isolated environment with external KMS versions, IAM/policies, ciphertext, and migration state | All sampled and boundary-case payloads decrypt/authenticate; counts/links match; service remains closed until restore checks pass |
| C31 | Restore with missing/unavailable key, KMS outage, provider account/region unavailable | Restore fails closed with explicit operational alarm; no plaintext/local key fallback; no false success |

### 8.4 End-to-end application workflow

| ID | Test | Expected outcome |
|---|---|---|
| C32 | Log/audit/exception/crash/browser/export scan using synthetic canary values and synthetic key material | Canary values, ciphertext, HMAC tokens, signed URLs, and key bytes absent from disallowed channels |
| C33 | Encrypted file upload to Storage and download/decryption | Storage contains ciphertext only; parser sees no bytes until GCM tag verifies; tampering deletes temp plaintext and fails |
| C34 | Production-like dependency/runtime matrix for supported Python/Node versions | Same fixtures pass on pinned supported versions; unsupported crypto configuration fails at startup |

Runtime tests C01-C34 become executable as their dependencies are implemented.
The fixture/spec reviews above are useful preparation, but no execution result
is implied here.

## 9. Workflow implementation dependencies

These are observed functional gaps from the current application, not
cryptographic design assumptions. Resolve each before enabling the related
plaintext/decryption path:

| Workflow gap | Required implementation dependency | Decryption/feature gate |
|---|---|---|
| Reviewer-decision persistence | Persist the reviewer's identity, target, action, timestamp, and non-sensitive decision metadata in `reconciliation_reviewer_decisions` or a reviewed equivalent. Enforce authorization and audit atomically with the review mutation; do not duplicate values in decision metadata. | Do not enable human-review plaintext release or accept/reject actions until the review event has durable, integrity-protected persistence and the field/role contract is enforced. |
| Discrepancy resolution is not atomic and the submitted value is not persisted as canonical state | Implement one transaction that validates current discrepancy/entity/source state, validates the typed field, persists the resolved canonical value and decision, and commits audit metadata without the value. Preserve source immutability. | Do not decrypt competing values for a resolution action or report resolution success until all writes/audit commit atomically. |
| Comparison evidence is incomplete (`comparison_details` is currently `{}`) | Define value-free, field-coded evidence and persist the relevant comparison result/score explanation. Ensure evidence is sufficient for the intended review decision and cannot include raw values unintentionally. | Do not claim evidence-backed review or expose comparison details until the output schema, completeness, and redaction are tested. Source-field review access is separately gated by its authorization/audit contract. |
| Export Storage and authorization are incomplete | Add a reviewed export-bucket lifecycle/configuration, tenant-scoped object policy, retention/deletion policy, field allowlist, actor/role authorization, audit, and signed-download flow. Remove unrestricted inline CSV fallback. | No export decryption or sensitive CSV delivery until storage, authorization, retention, audit-before-release, and failure behavior pass tests. |
| Import-to-review-to-export E2E is not verified | Add synthetic fixtures and an E2E harness covering tenant isolation, ingest, encryption, matching, decision, discrepancy, export, logs, audit, and cleanup, including partial failures and retries. | Do not enable the integrated production workflow until this E2E path and the relevant C32-C34 tests pass. |

These dependencies do not require all future integration tests to pass before
schema or broker development begins. Implement and test each component in
sequence; gate only the corresponding sensitive operation on its prerequisites.

## 10. Performance and capacity validation

No performance claim or supported encrypted matching capacity is established
by this contract. Measure with synthetic datasets only, on recorded,
representative deployment profiles. Record hardware/instance size, OS,
container limits, Python/Node/library versions, KMS provider/region and
latency, dataset row/field/value distributions, payload sizes, concurrency,
warm/cold cache state, run duration, throughput, p50/p95/p99 latency, CPU,
peak RSS, temporary-storage use, retries, and errors. Compare against
product-owner-approved service and resource targets; do not invent threshold
results or infer production performance from local runs.

The benchmark suite must measure:

- Import parse, normalization, encryption, KMS wrapping, and database insert
  throughput separately and end to end, including duplicate-heavy and
  maximum-sized synthetic inputs.
- AES-GCM encrypt/decrypt throughput for the 16 MiB record and 50 MiB file
  boundaries, plus broker request overhead and external KMS latency.
- Splink runtime and peak worker memory with encrypted retrieval/decryption,
  realistic synthetic blocking distributions, and encrypted-file handling.
- Peak worker and broker memory, temporary-file usage, and cleanup at
  configured container limits; verify no plaintext parser use before file tag
  verification.
- Concurrent import/matching jobs, KMS throttling/backpressure, DB contention,
  budget reservations, retry storms, and broker saturation.
- Lease expiration/reassignment during slow KMS, decryption, Splink execution,
  and writes. Measure time to stop, confirm output discard, and prove no
  post-loss writes.
- A maximum supported matching records-per-run value derived from repeatable
  measurements and approved resource/SLA budgets. The current matcher loads
  the run's source rows into a DataFrame; no validated maximum supported run
  size is established here. An iteration setting is not a row-capacity
  guarantee.

Retain benchmark scripts, synthetic data generators, and measurement reports
as test artifacts. Repeat after crypto-library, KMS, Splink, worker resource,
or data-shape changes. Performance limits may require smaller job scopes and
therefore new DEKs; do not raise cryptographic bounds to solve capacity issues.

## 11. Unresolved decisions and implementation blockers

Resolve and record these decisions; they cannot be inferred safely from the
repository:

1. **Formal approval and accountable owners:** security owner, data owner,
   institutional owner, and sign-off record for this contract.
2. **Data classification/legal basis:** actual source fields, subject
   populations, permitted purposes, retention/deletion, residency, access
   obligations, and any institution-specific handling requirements. No legal
   conclusion is made here.
3. **Human access matrix:** whether owner/admin, member, or a future dedicated
   reviewer role can decrypt each personal/financial/eligibility field; whether
   members can export plaintext.
4. **Provider and operating region:** production KMS/HSM choice from AWS KMS,
   Google Cloud KMS, Azure Key Vault, OpenBao Transit, or institution-managed
   HSM; workload identity, key ownership, provider context semantics, key
   retention, recovery, SLA, and cost.
5. **Crypto-broker placement and identity:** where it runs, how worker claims
   are authenticated without a general KMS credential, and how audit commits
   are made atomic with plaintext release.
6. **Normalization profiles:** precise issuer/jurisdiction rules for every
   identifier tokenized; no identifiers should enter tokenization before the
   profile is approved.
7. **Source ID and row-hash transition:** the proposed additive HMAC
   fingerprint approach is specified in section 5.3, but the canonicalization
   profile, HMAC key lifecycle, historical coverage, legacy-writer cutoff,
   and idempotency migration need review. Preserve existing source IDs,
   hashes, unique index behavior, and immutable rows until an approved
   transition is tested.
8. **File upload encryption boundary:** the proposed 50 MiB ingress boundary
   is specified in section 3.2, but the trusted ingress placement, file/object
   lifecycle, temp-storage/memory budget, retry semantics, and Storage
   integration must be selected and tested. Never expose keys to the browser.
9. **Retention/cleanup:** original source object, failed imports, exports,
   entity records, evidence, reviewer rationale, audit events, old key
   versions, and backups.
10. **Operational and cryptographic caps:** approve or revise the proposed
    2^22 invocation, 1 GiB aggregate-byte, 16 MiB record, and 50 MiB file
    limits after a documented GCM security analysis and capacity tests.
    Establish lease/budget concurrency enforcement, Splink row/memory bounds,
    concurrent-job limits, and a measured maximum matching run size.
11. **Recovery targets:** RPO/RTO, key escrow/dual control, provider loss,
    restore frequency, and approval to retire old key versions.
12. **Current workflow gaps:** see section 9 for required implementation
    dependencies and the affected decryption/export enablement gates.

Until the applicable blockers, architecture choices, and approval gates are
resolved, **Phase 2A.3.3 is not cleared to begin implementation**. This
contract may be submitted for product-owner and security-owner review; approval
must record outstanding institutional/legal decisions as unresolved rather
than imply they have been decided. Synthetic fixture preparation and
performance-harness design are safe; production crypto/schema code and
plaintext retirement are not.

## 12. Decision record and handoff

Provisional recommended baseline:

1. Python `cryptography` AESGCM plus Node.js built-in `node:crypto` AES-256-GCM
   for interoperable bounded messages.
2. 32-byte CSPRNG DEKs, 12-byte random nonces, 16-byte tags appended to
   ciphertext, and the provisional combined limits and analysis in section
   3.2; invocation count alone is not a security guarantee.
3. Exact binary AAD v1 and strict versioned serialization as specified above.
4. Separate DEKs for each source-file object, each bounded import-job
   row-payload scope, and each entity envelope; independently keyed
   HMAC-SHA-256 token scopes.
5. External KMS/HSM KEKs, production workload identity, and a crypto broker;
   no production plaintext keys in the database and no KMS credentials in
   workers.
6. Additive sidecar storage, no mutation of immutable source rows, deny direct
   table access, scoped RPC authorization, verified dual-read transition, and
   separately approved later plaintext retirement.

These are recommendations for approval, not stakeholder-approved choices.
The final approval record must include the resolved blockers, library/package
versions, provider/region, operational limits, exact role/field matrix,
normalization profiles, backup/restore test evidence, and named approvers.

### Decision register

| Category | Register |
|---|---|
| **Verified facts** | Current source values and upload objects are plaintext; source rows are immutable; current import dedupe uses `(import_job_id, source_record_id, row_hash)` with SHA-256 canonical JSON in the active worker; current workflows and legacy pgsodium containment remain as documented in sections 1 and 5.3. |
| **Proposed technical requirements** | AES-256-GCM and cross-runtime serialization; 32-byte DEKs, random 12-byte nonces, 16-byte tags; bounded usage with durable concurrent reservations; broker-performed human review/export decryption; claim/field/purpose-scoped worker handoff only if needed; ciphertext-only Storage; additive HMAC fingerprint migration; fail-closed authorization and audit ordering. |
| **Product-owner decisions** | Which fields are recoverable and for which purpose; reviewer roles; entity/member visibility; export fields, roles, formats, and retention; operational limits/SLOs; accepted matching capacity and workflow priorities. |
| **Institutional/legal decisions** | Actual data classifications and permitted processing; legal basis, subject rights, retention/deletion, residency, institutional policy, key custody/escrow, recovery authority, and any approval requirements. No legal or regulatory outcome is asserted. |
| **Outstanding blockers** | Production KMS/HSM provider and region; crypto-broker placement/identity; field-role matrix; normalization profiles; upload ingress and temp-storage design; GCM usage analysis and cap approval; historical fingerprint/backfill and legacy-writer transition; workflow dependencies in section 9; recovery targets and successful restore evidence. |

**Review disposition:** the revised contract is ready to submit for
product-owner and security-owner review and approval. It is not itself approved,
does not complete Phase 2A.3.2, and does not authorize or clear Phase 2A.3.3.
Obtain named sign-off and resolve or explicitly defer the owner-specific
decisions before implementation. Institutional/legal gates remain unresolved
until the relevant authority decides them.
