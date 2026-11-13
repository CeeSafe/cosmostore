# ADR-0043: Bucket policies

**Status:** accepted for M5 (item 3, slice 1: bucket policies), 13 Nov 2026, and built (`src/s3/policy.cee`,
`src/s3/server.cee`, `src/store/checkpoint.cee`). The public-access block and an ACL compatibility mode are later
slices of the same item.

## Context

- **Who a request is today** (ADR-0008, ADR-0011): a request signed with an access key of the credentials file, by
  header or presigned URL, or a POST form signed with one (ADR-0018). Every such key may do everything, and a request
  that is not signed is refused with AccessDenied. There are no users, accounts or bucket owners.
- **What S3 adds with a bucket policy:** a JSON document on the bucket whose statements allow or deny actions on the
  bucket and its objects to principals, under conditions. An explicit Deny wins; an anonymous request needs an Allow;
  a principal of the bucket's own account is allowed by its own permissions unless a policy denies it. The account
  root is never denied the policy calls themselves, so a policy cannot lock the owner out.
- **The choice made with the user** (13 Nov 2026): principals are the access keys of the credentials file, and `*`
  for anyone, anonymous requests included. Named users and accounts are not introduced.

## Decision

1. **Two kinds of requester.** A *key*: a request signed with a configured access key, which may do everything a
   policy does not deny, as now. *Anonymous*: a request with no `Authorization` header and no presigned-URL
   parameters, which may do only what a policy allows. Every key is of the one account that owns every bucket.
2. **A policy is stored as given,** a `BucketConfig` record of kind 4 (at most 20 KiB of JSON), checked when it is
   put and parsed again when it is used. Checkpoint format 7 adds it to a bucket's entry; formats 1 to 6 load.
   PutBucketPolicy (204), GetBucketPolicy (the document, or 404 NoSuchBucketPolicy) and DeleteBucketPolicy (204).
3. **The language:** `Version` (`2012-10-17` or `2008-10-17`), `Id`, and `Statement`, one object or an array. Each
   statement has `Sid`, `Effect` (`Allow`, `Deny`), `Principal` or `NotPrincipal`, `Action` or `NotAction`,
   `Resource` or `NotResource`, and `Condition`; a field that takes values takes one string or an array.
   - **Principals:** `"*"`, `{"AWS": "*"}`, and `{"AWS": "arn:aws:iam:::user/<access-key-id>"}` naming a configured
     key. A key that is not configured is MalformedPolicy when the policy is put, and matches nothing if the
     credentials file loses it later. Other principal kinds (`CanonicalUser`, `Service`, `Federated`) are
     NotImplemented. `NotPrincipal` goes only with `Deny`: with `Allow` it would grant to everyone else, anonymous
     requests too, and S3 refuses it (MalformedPolicy).
   - **Actions:** `*`, or `s3:` and a name, with `*` and `?` as wildcards, matched without regard to case. Names S3
     has and CosmoStore does not serve are accepted and never match a request.
   - **Resources:** `arn:aws:s3:::<bucket>` or `arn:aws:s3:::<bucket>/<key pattern>`, `*` and `?` as wildcards in
     the key, case-sensitive. A resource of another bucket is MalformedPolicy, as S3 answers.
   - **Conditions:** an operator, then condition keys, then one value or a list (any value matches; every key and
     every operator of a statement must). Operators: `StringEquals`, `StringNotEquals`, `StringEqualsIgnoreCase`,
     `StringNotEqualsIgnoreCase`, `StringLike`, `StringNotLike`, `Bool`, `IpAddress`, `NotIpAddress`,
     `NumericEquals`, `NumericNotEquals`, `NumericLessThan`, `NumericLessThanEquals`, `NumericGreaterThan`,
     `NumericGreaterThanEquals` and `Null`. Keys: `aws:SecureTransport`, `aws:SourceIp`, `aws:Referer`,
     `aws:UserAgent`, and, for listings, `s3:prefix`, `s3:delimiter` and `s3:max-keys`. A key a request does not have
     fails every operator but the negated ones, which hold, and `Null`, which says whether it is absent. The IP
     operators take addresses and CIDR ranges, IPv4 and IPv6; an IPv4 client seen as an IPv4-mapped IPv6 address
     matches IPv4 ranges. Numeric operators take only `s3:max-keys`.
   - **Refused as NotImplemented when the policy is put**, since a statement CosmoStore cannot evaluate exactly must
     not be stored: any other condition key or operator, `...IfExists`, `ForAllValues:` and `ForAnyValue:`, and
     policy variables (`${...}`). Anything not JSON, or not of this shape, is MalformedPolicy.
4. **The decision for a request,** given its action, its resource (`<bucket>` or `<bucket>/<key>`) and its facts:
   - a statement *applies* when its principal, action, resource and every condition match;
   - an applying Deny refuses the request (AccessDenied);
   - otherwise a key is allowed, and an anonymous request is allowed only if an Allow applies;
   - a key is never refused GetBucketPolicy, PutBucketPolicy or DeleteBucketPolicy, so a policy that denies
     everything can still be replaced.
5. **The actions of the requests:**

   | Request | Action |
   |---|---|
   | GET, HEAD object (`versionId`: `s3:GetObjectVersion`) | `s3:GetObject` |
   | GetObjectAttributes (with `versionId`: `s3:GetObjectVersionAttributes`) | `s3:GetObjectAttributes` |
   | PUT object, POST object, CopyObject's target, CreateMultipartUpload, UploadPart, UploadPartCopy's target, CompleteMultipartUpload | `s3:PutObject` |
   | a copy's source (with `versionId`: `s3:GetObjectVersion`), checked against the source bucket's policy | `s3:GetObject` |
   | DELETE object, each key of DeleteObjects (with a version id: `s3:DeleteObjectVersion`) | `s3:DeleteObject` |
   | AbortMultipartUpload; ListParts | `s3:AbortMultipartUpload`; `s3:ListMultipartUploadParts` |
   | Get-, Put-, DeleteObjectTagging (with `versionId`: `s3:GetObjectVersionTagging` and so on) | `s3:GetObjectTagging`, `s3:PutObjectTagging`, `s3:DeleteObjectTagging` |
   | HeadBucket, ListObjects v1 and v2; ListObjectVersions; ListMultipartUploads | `s3:ListBucket`; `s3:ListBucketVersions`; `s3:ListBucketMultipartUploads` |
   | GetBucketLocation; DeleteBucket | `s3:GetBucketLocation`; `s3:DeleteBucket` |
   | Get-, Put-, DeleteBucketTagging | `s3:GetBucketTagging`, `s3:PutBucketTagging` (both changes) |
   | Get-, Put-, DeleteBucketLifecycle | `s3:GetLifecycleConfiguration`, `s3:PutLifecycleConfiguration` (both changes) |
   | Get-, PutBucketVersioning | `s3:GetBucketVersioning`, `s3:PutBucketVersioning` |
   | Get-, Put-, DeleteBucketPolicy | `s3:GetBucketPolicy`, `s3:PutBucketPolicy`, `s3:DeleteBucketPolicy` |

   ListBuckets, CreateBucket and the stats endpoint have no bucket policy: keys only, as now. A refused key of
   DeleteObjects gets an AccessDenied error in the result, and the other keys go on.
6. **The facts:** `aws:SecureTransport` is whether the server listens with TLS; `aws:SourceIp` is the connection's
   peer (no proxy header is trusted); `aws:Referer` and `aws:UserAgent` are the request's fields; `s3:prefix` is the
   listing's prefix, empty when it has none (as S3's own examples of root listing assume), and `s3:delimiter` and
   `s3:max-keys` are there when the request gives them.
7. **Anonymous bodies are not signed:** an anonymous PUT is `UNSIGNED-PAYLOAD` unless its `x-amz-content-sha256`
   gives a digest (checked) or `STREAMING-UNSIGNED-PAYLOAD-TRAILER` (aws-chunked, trailers checked); a signed
   streaming payload without a signature is InvalidRequest.
8. **Without policies nothing changes, and nothing is spent.** The server keeps two counts: buckets with a policy,
   and buckets whose policy has a Deny. A key's request reads its bucket's policy only when the second is not 0; an
   anonymous request only when the first is not 0, and is refused at once otherwise, as now. The counts are made from
   the store at start and again after every PutBucketPolicy, DeleteBucketPolicy and DeleteBucket, before the
   response, so a request that starts after the response sees the change. A request that reads a policy takes the
   store's lock once and parses the document: a few microseconds for a policy of a few statements.
9. **A stored policy that does not parse** (it cannot happen through the API) refuses the requests it is read for,
   except a key's policy calls, so it can be replaced.

## Consequences

- A bucket can be made public for reading with the policy S3 users already write, and keys can be kept out of
  buckets or prefixes. Nothing about a key's request changes until a policy denies something.
- An anonymous request to a bucket without a policy is still AccessDenied, without a lookup.
- A store with a policy has checkpoint format 7, which an older build refuses.
- The tests of s3-tests that need a second account (the `alt` user refused by default) still fail: every key is of
  one account.

## Rejected

- **Named users in the credentials file** (the other option of 13 Nov): policies could name users as AWS does, but
  the credentials file's format changes and every existing file needs a migration story. Access keys are the
  principals this server already has.
- **Accepting a policy with conditions it cannot evaluate:** an Allow with an ignored condition opens more than it
  says, and a Deny with one closes more. Refusing it at put time is the only safe answer.
- **Parsing every policy once and keeping the parsed form** in the S3 layer: one more structure to keep in step with
  the store, for a cost that is small next to a request. Kept for when a measurement says otherwise.
- **Trusting `X-Forwarded-For` for `aws:SourceIp`:** any client can send it.
