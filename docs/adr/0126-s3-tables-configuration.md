# ADR-0126: S3 Tables' encryption, tags and storage class (M30)

**Status:** proposed, 25 Nov 2026, with the owner's choices made: encrypted tables compacted ("Compacted"), and a
write asking for another encryption than its table's refused ("Refused"). M30 is ADR-0125's item A (the owner: "A:
encryption, tags").

## Context

- **The calls** (botocore 1.44.9's model):
  - **Encryption:**
    - `PUT`/`GET`/`DELETE /buckets/{arn}/encryption`, and `GET /tables/{arn}/{namespace}/{name}/encryption`;
    - each is `{"encryptionConfiguration": {"sseAlgorithm": "AES256" | "aws:kms", "kmsKeyArn": …}}`;
    - CreateTableBucket and CreateTable take it too.
  - **Tags:**
    - `POST /tag/{resourceArn}` with `{"tags": {…}}`;
    - `DELETE /tag/{resourceArn}?tagKeys=…`;
    - `GET /tag/{resourceArn}`, answering `{"tags": {…}}`;
    - on table buckets and tables, and the creates' `tags`.
  - **Storage class:**
    - `PUT`/`GET /buckets/{arn}/storage-class` and `GET /tables/{arn}/{namespace}/{name}/storage-class`;
    - each is `{"storageClassConfiguration": {"storageClass": "STANDARD" | "INTELLIGENT_TIERING"}}`;
    - the creates take it.
- **What CosmoStore has:**
  - **SSE-S3 and SSE-KMS (ADR-0071, `src/s3/sse.cee`):** an object's data key wrapped by a master key, its stream
    sealed in AES-256-GCM chunks; a bucket's default encryption sealing every PUT that asks for none.
  - **Where the sealing happens:** at the S3 layer. Its keys are the S3 app's.
  - **Who reads the store directly:** the catalog's metadata files and manifests, and compaction's reads and
    writes, go to the store and never unseal. Compaction leaves a sealed file as it is today ("its stored bytes are
    not its Parquet bytes").
  - **Object tags and storage classes (M7),** and policy conditions on tags for S3 (`s3:ExistingObjectTag`).
- **What S3 Tables does:**
  - **A table bucket's encryption** is its tables' default. A table may set its own at create, and not change it
    after.
  - **Every file of a table is sealed with its key:** its data, deletes, manifests and metadata files.
  - **Maintenance (compaction, expiry)** works on encrypted tables, with the key's permissions.

## Decision (proposed)

1. **Tags** (slice 1):
   - kept per table bucket and table, as the creates' `tags` and the three calls set them, within S3's limits (50 a
     resource, keys to 128 characters, values to 256);
   - removed with their resource;
   - `aws:ResourceTag/<key>` conditions in table bucket and table policies see them, and `aws:RequestTag` and
     `aws:TagKeys` on the calls that set them.
2. **Storage class** (slice 1):
   - a table bucket's, `STANDARD` by default, inherited by a table at its create, which may give its own;
   - given to every object written in the table's warehouse that asks for none.
   - `INTELLIGENT_TIERING` is taken as CosmoStore's storage classes take it (M7).
3. **The encryption configuration** (slice 2):
   - kept per table bucket (put, get, delete) and per table (set at create, from the bucket's when it gives none,
     never changed);
   - `aws:kms` names one of this server's KMS keys, by ARN or id;
   - a table's is answered by `GetTableEncryption` (`AES256` when none was set).
4. **Every file of an encrypted table sealed** (slices 2 to 4):
   - **through S3:** a PUT, POST or multipart upload into a table's warehouse that asks for no encryption is sealed
     with the table's configuration, as a bucket's default seals it. One that asks for another is refused, as S3
     Tables refuses;
   - **by the catalog:** its metadata files sealed when written and unsealed when read;
   - **by compaction:** its inputs, deletes and manifests unsealed as read; its outputs, manifests and lists sealed
     as written, with the table's key.
   - **The keys** reach the catalog and compaction from the S3 app, and are never written in the clear.
5. **The checks** (slice 5):
   - the AWS CLI and boto3 set, read and remove each;
   - the SDK matrix sees the same answers, and Terraform's `aws_s3tables_table_bucket` sets encryption and tags;
   - a KMS table's every file is sealed in the store, its tables compacted, and read back by PyIceberg and Iceberg
     Java;
   - tag conditions allow and deny as written.

## Slices

1. Tags and storage class (§1, §2).
2. The encryption configuration, and S3's writes into a warehouse sealed by it (§3, §4 through S3).
3. The catalog's own files sealed and unsealed (§4).
4. Compaction of an encrypted table (§4).
5. The checks (§5).
6. The exit review.

## For the owner to decide

- **Encrypted tables' compaction:**
  - **compacted, unsealing and sealing (recommended):** as S3 Tables does, so a KMS table does not grow small files;
  - **left as they are,** as sealed files are today: less to build, and a KMS table's files are never merged.
- **A write that asks for another encryption than its table's:**
  - **refused (recommended):** as S3 Tables refuses, so a table's files are all under its own key;
  - **taken as asked,** as an S3 bucket's default allows.

## Consequences

- **Tools that set S3 Tables' encryption, tags or storage class are taken,** and a KMS table's files are all sealed
  with its key, compaction's included.
- **The catalog and compaction hold keys:** each read of an encrypted table's metadata unwraps its data key.
- **On a cluster, a table bucket's settings come after its create** (found by CI in slice 1): a shard's write does not
  see a bucket made in the same request (ADR-0058). So a create that sets tags, a storage class or an encryption is
  refused before anything is made, and its client sets them with their own calls. A table's create is not
  affected, since its bucket already exists. Taking them in one request would need the store to stage a bucket and a
  write into it together: for the owner, at M30's exit review.
