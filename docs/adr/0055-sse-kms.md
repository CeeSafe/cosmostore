# ADR-0055: SSE-KMS with a local KMS key file

**Status:** accepted for M5 (item 4, its last part), 14 Nov 2026, as recommended (the owner: "I accept ADRs as
recommended"), and built (`src/s3/sse.cee`, `src/s3/serve.cee`, `src/s3/policy.cee`, `src/store/bucket_config.cee`),
asked for by the owner as the remainder of ADR-0046 ("Continue to those remaining").

## Context

- **What S3 offers.** SSE-KMS (`x-amz-server-side-encryption: aws:kms`): an object's data key comes from AWS KMS,
  under a KMS key the request names (`x-amz-server-side-encryption-aws-kms-key-id`, an id or an ARN) or the
  account's default key (`aws/s3`). The request may add an encryption context (`x-amz-server-side-encryption-
  context`, base64 JSON) and ask for a bucket key (`...-bucket-key-enabled`); a bucket's default may be `aws:kms`
  with a `KMSMasterKeyID`. `aws:kms:dsse` seals twice. Bucket policies use `s3:x-amz-server-side-encryption` and
  `s3:x-amz-server-side-encryption-aws-kms-key-id` to require it.
- **What CosmoStore has** (ADR-0046): SSE-S3 under master keys from a file, SSE-C, envelopes in a version's
  metadata, a data key per object, and the field's other values refused as NotImplemented. ADR-0046 put SSE-KMS
  "after this, behind a provider interface".
- **No KMS to call.** CosmoStore is one process with no account and no KMS service; calling AWS KMS or Vault would
  need an HTTP client with its own credentials and availability, a different project. What S3's clients and tools
  need from SSE-KMS is the API: a key chosen by id, the answers that name it, the bucket default, the policy keys.

## Decision

1. **A KMS key file** (`serve --kms-key-file <path>`), in the key file's format (ADR-0046 §4): lines of
   `<key id> <base64 of 32 bytes>`, read once at start; a file that does not parse stops `serve`. Its keys are apart
   from SSE-S3's master keys: an id names a key of its own kind. Without the option, SSE-KMS is NotImplemented, as
   before.
2. **A request names its key** by id, or by an ARN or alias path whose last `/`-piece is the id; without one, the
   file's first key is the default, as `aws/s3` is S3's. An id the file does not have is InvalidArgument. The KMS
   fields without `aws:kms` are InvalidArgument; an encryption context and `aws:kms:dsse` are NotImplemented; a
   bucket key changes nothing here and is reported as off.
3. **The envelope** is ADR-0046's, mode `kms`: `v1.kms.<key id>.<nonce>.<wrapped data key>`, the data key wrapped
   under the KMS key with `kms` as associated data, so a master key of the same id does not open it. Reads need no
   field; an id no longer in the file is InternalError and a line in the log, as for SSE-S3.
4. **Answers** carry `aws:kms` and the key's id (`x-amz-server-side-encryption-aws-kms-key-id`), on writes and reads.
   The ETag is not the plaintext's MD5, as S3's is not: HMAC-SHA256 of it under the object's data key, 16 bytes, so
   a part uploaded again keeps its ETag.
5. **Multipart:** CreateMultipartUpload names the key; UploadPart and Complete may repeat the upload's fields, which
   are then ignored (the upload's key seals every part), as S3 and s3-tests have it. The same fields into an upload
   in the clear or under SSE-C are InvalidArgument.
6. **A bucket's default** may be `aws:kms`, with or without `KMSMasterKeyID` (stored as `aws:kms` or `aws:kms <id>`
   in `BucketConfig` kind 11; no format change). It needs the KMS key file (NotImplemented without) and, when it
   names a key, one the file has (InvalidArgument).
7. **Policy condition keys** `s3:x-amz-server-side-encryption`, `s3:x-amz-server-side-encryption-aws-kms-key-id` and
   `s3:x-amz-server-side-encryption-customer-algorithm`, from the request's fields (a bucket's default is not the
   request's, as in S3), with the string operators and `Null`.

## Consequences

- S3's clients, tools and policies that use SSE-KMS work, and objects are sealed under keys an operator names and
  can keep apart (a key per application or tenant).
- **It is not a KMS:** the keys are in a file on the server, like SSE-S3's; there is no per-key access control
  beyond bucket policies, no audit of key use beyond the audit log, no key rotation under one id (rotate by a new
  id and a copy onto itself), and no grants. Losing the file loses the objects sealed under its keys.
- `aws:kms` without a key id is accepted with the default key, as AWS documents; s3-tests' `test_sse_kms_no_key`
  expects a refusal (RGW's behaviour) and fails.

## Rejected

- **Calling AWS KMS or HashiCorp Vault** now: a client, credentials and a dependency on another service's
  availability for every PUT and GET. A provider behind the same envelope can come later: the envelope names the
  key's id, and only `sealedDataKey` and `newKmsSeal` call the keys.
- **One file for both kinds of key:** an SSE-S3 master key rotates by order (the first seals), a KMS key is chosen
  by name; one file would make a rotation move every KMS default.
- **Refusing `aws:kms` without a key id** (RGW): AWS uses a default key, and clients rely on it.
