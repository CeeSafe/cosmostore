# ADR-0018: POST object (browser form uploads with a SigV4 policy)

**Status:** accepted for M3 slice 11 (`src/s3/form.cee`, `src/s3/post.cee`), 8 Nov 2026

## Context

A browser uploads to S3 with an HTML form. The request is a POST to the bucket with a `multipart/form-data` body:
- **fields first:** `key`, `policy`, the signature fields, `Content-Type`, `x-amz-meta-*`, `success_action_*`, and
  others;
- **then the file.**

The policy is base64 JSON: an expiration, and conditions on the fields (`eq`, `starts-with`,
`content-length-range`). The form signs the policy. Any field the policy does not name is refused.

SDKs make these forms: boto3's `generate_presigned_post`, and the JavaScript SDK's `createPresignedPost`. With
SigV4 the signature is the HMAC-SHA256 of the base64 policy with the credential's signing key.

## Decision

1. **Routing.** A POST to a bucket, with no query, whose Content-Type is `multipart/form-data`, is a POST object.
   It is routed before header authentication: the form authenticates it.
2. **The form is streamed** (`FormReader`, RFC 7578):
   - fields are collected whole, at most 64 KiB before the file;
   - the `file` part's bytes go straight to an `ObjectWriter` on worker threads, as a PUT body does. Only bytes that
     could still begin the boundary are held back;
   - fields after the file are ignored, as S3 does, and the rest of the body is read;
   - a 100 MB POST kept the server at 6 to 8 MB of memory.
3. **The signature:** `x-amz-algorithm` (AWS4-HMAC-SHA256), `x-amz-credential`, `x-amz-date` and
   `x-amz-signature`.
   - The credential goes through the same parser as header and query auth.
   - SigV2 forms (`AWSAccessKeyId`, `signature`) get the SigV2 refusal (ADR-0013). So s3-tests' POST tests, which
     all sign with SigV2, stay outside the subset.
4. **The policy** (`parsePolicy`) is read with a small JSON reader. Strings take `\uXXXX` escapes, surrogate pairs
   included. Anything else is InvalidPolicyDocument: a missing expiration or conditions, an unknown operator
   (operators are case-sensitive, as in S3), a field without `$`, or trailing text.
5. **The checks** (`checkPolicy`), all before the file is written:
   - the policy has not expired;
   - each condition holds. `bucket` is the bucket. `key` is compared after `${filename}` is replaced by the file's
     name;
   - every field but `policy`, `x-amz-signature`, `file` and `x-ignore-*` has a condition;
   - otherwise the answer is AccessDenied.
   - `content-length-range` is enforced as the file streams (EntityTooLarge) and at its end (EntityTooSmall). A
     refused file's extents are removed.
6. **What is stored:**
   - the Content-Type field;
   - `x-amz-meta-*` and the stored headers (ADR-0012);
   - the `tagging` field, Tagging XML, as tags (ADR-0017);
   - a CRC64NVME checksum (ADR-0015).
7. **The answer:**
   - `success_action_redirect`: a 303 to it, with `bucket`, `key` and `etag` added;
   - else `success_action_status`: 200, 201 (with a PostResponse), or 204, the default.
   - The ETag and Location are always sent.

## Rejected

- **Reading the whole form into memory.** Objects reach 5 GiB.
- **SigV2 POST,** for s3-tests. It needs HMAC-SHA1, which lib/std lacks (G26), and it is deprecated; SDKs sign
  SigV4.

## Tests

- **Unit:**
  - the form reader on a form split at every byte. Its file holds near-boundaries, CRLFs and bytes 0 to 255, and a
    field follows the file;
  - a quoted boundary;
  - the policy reader and checks: JSON escapes, expiry, another bucket, a key outside its prefix, an uncovered
    field, a condition on a missing field, and six malformed documents.
- **boto3** (`generate_presigned_post` with s3v4, posted as `multipart/form-data`):
  - 204, 201 and the 303 redirect;
  - metadata and `${filename}`;
  - refusals: a file too large, a field outside the policy, a changed policy, an expired policy, and a key outside
    the prefix.
- **JavaScript** (`createPresignedPost`, posted with `FormData`): stored, and a file too large.
- **By hand:** 100 MB with curl took 0.85 s, the MD5 matched, and server memory stayed at 6 to 8 MB.

## Not yet

- Checksum fields on POST (`x-amz-checksum-*`).
- ACL fields beyond a `private` condition: there are no ACLs.
