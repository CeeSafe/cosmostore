# ADR-0044: The public-access block and a policy's status

**Status:** accepted for M5 (item 3, slice 2), 13 Nov 2026, and built (`src/s3/policy.cee`, `src/s3/server.cee`,
`src/store/bucket_config.cee`, `src/store/checkpoint.cee`). An ACL compatibility mode is the next slice.

## Context

- **Bucket policies** (ADR-0043) let a bucket be opened to anonymous requests. Nothing yet says whether a bucket
  *is* open, or keeps one from being opened by mistake.
- **S3 has both.** GetBucketPolicyStatus says whether a bucket's policy is public. The public-access block is four
  settings on a bucket: `BlockPublicPolicy` refuses a public policy when it is put, `RestrictPublicBuckets` closes a
  bucket whose policy is public to everyone outside the owner's account, and `BlockPublicAcls` and `IgnorePublicAcls`
  do the same for ACLs.
- **There is one account here** (ADR-0043 §1): the requesters outside it are the anonymous ones. There are no ACLs
  yet.

## Decision

1. **The block is stored with the bucket,** a `BucketConfig` record of kind 5 whose value is one byte: bit 0
   `BlockPublicAcls`, bit 1 `IgnorePublicAcls`, bit 2 `BlockPublicPolicy`, bit 3 `RestrictPublicBuckets`. An empty
   value clears it; a block with every setting off is still a block. Checkpoint format 8 adds it to a bucket's
   entry; formats 1 to 7 load. PutPublicAccessBlock (200; a setting the document leaves out is off),
   GetPublicAccessBlock (the four settings, or 404 NoSuchPublicAccessBlockConfiguration) and DeletePublicAccessBlock
   (204). There is no account-level block: there is one account, and no S3 Control API.
2. **A policy is public** when one of its Allow statements is for anyone (`"*"` or `{"AWS": "*"}`) and is not kept
   to fixed addresses. A statement is kept to fixed addresses by an `IpAddress` condition on `aws:SourceIp` whose
   ranges are each no wider than /8 for IPv4 and /32 for IPv6, the line S3 draws. No other condition of ADR-0043 §3
   makes a statement less than public: a referer, a user agent or TLS is anyone's to send. A statement that names
   access keys is never public, since every key is of the owner's account.
   - **Deny statements are not counted.** A policy that allows anyone and denies the same again is called public.
     The answer errs towards "public", the side on which the block closes more.
   - GetBucketPolicyStatus answers `IsPublic` `true` or `false`. For a bucket without a policy it answers `false`,
     as RGW does and the Ceph tests expect, where S3 answers NoSuchBucketPolicy: with ACLs to come, a bucket's
     status will not depend on its having a policy. A stored policy that does not parse (ADR-0043 §9) is not public:
     it opens nothing.
3. **What the settings do:**
   - `BlockPublicPolicy`: PutBucketPolicy with a public policy is AccessDenied. A policy the bucket already has
     stays, as in S3.
   - `RestrictPublicBuckets`: while the bucket's policy is public, an anonymous request is refused whatever the
     policy allows it, a statement for fixed addresses included: the whole policy stops opening the bucket. Keys
     are not touched. A policy that is not public works as before.
   - `BlockPublicAcls` and `IgnorePublicAcls` are stored and returned and do nothing yet: there are no ACLs to
     block or ignore. The ACL slice gives them their meaning.
4. **The actions:** GetBucketPolicyStatus is `s3:GetBucketPolicyStatus`; GetPublicAccessBlock is
   `s3:GetBucketPublicAccessBlock`; PutPublicAccessBlock and DeletePublicAccessBlock are
   `s3:PutBucketPublicAccessBlock`. They are checked as every other call (ADR-0043 §4). A key can be denied them by
   a policy, and can always replace that policy.
5. **No cost without policies, as before** (ADR-0043 §8). The block is read only by an anonymous request to a bucket
   that has a policy, under the lock that request already takes for the policy, and by PutBucketPolicy when the
   policy it was given is public. The two counts do not change: the block opens nothing, so no request needs to
   know of a block where there is no policy.

## Consequences

- A bucket can be kept from being made public, and one that was made public can be closed without touching its
  policy.
- A store with a public-access block, or checkpointed by this build, has checkpoint format 8, which an older build
  refuses.
- `BlockPublicAcls` and `IgnorePublicAcls` can be set today and take effect when ACLs arrive.
- PutBucketPolicy reads the block and then writes the policy in two turns of the store's lock. A
  PutPublicAccessBlock that runs between them is concurrent with the policy call, and either order is a correct
  answer; a public policy that slips in this way is still closed by `RestrictPublicBuckets`.

## Rejected

- **Counting Deny statements** to call fewer policies public: it needs the reasoning S3 does with a solver, and a
  wrong "not public" would leave a bucket open under a block. An over-wide "public" only refuses more.
- **Refusing a block while the bucket's policy is public,** or deleting the policy: S3 does neither.
- **NoSuchBucketPolicy for the status of a bucket without a policy:** it is what S3 answers, but the Ceph tests
  and RGW answer `false`, and the status will soon cover ACLs too.
- **An account-level block:** there is one account and no API to carry it; a block on every bucket says the same.
