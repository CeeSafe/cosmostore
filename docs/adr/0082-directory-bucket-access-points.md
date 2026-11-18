# ADR-0082: Access points of directory buckets

**Status:** proposed, 18 Nov 2026; its three slices built the same day. The owner asked for this next ("Take on Access points on directory buckets next"),
after M8 closed with it refused (ADR-0080 §6). It extends ADR-0076 (access points) and ADR-0080 (directory buckets).

## Context

- **AWS's pages** (the S3 user guide's "access points for directory buckets", its naming, restrictions and policies
  pages, and the S3 Control API reference for CreateAccessPoint, Get/Put/DeleteAccessPointScope,
  ListAccessPointsForDirectoryBuckets, GetAccessPoint and PutAccessPointPolicy; read 18 Nov 2026):
  - **Names:** `<base>--<zone-id>--xa-s3`, made in the bucket's zone and unique there. The base is 3 to 50 lowercase
    letters, digits and `-`, and does not begin or end with `-`. The alias is the name itself. The ARN is
    `arn:aws:s3express:<region>:<account>:accesspoint/<name>`. Policies name access points by ARN; requests cannot.
  - **One bucket each:** an access point belongs to one directory bucket for good. It may be deleted, and its name
    made again for another bucket.
  - **Scope:** an optional `Scope` of `Prefixes` (all together under 256 bytes) and `Permissions` (GetObject,
    GetObjectAttributes, PutObject, DeleteObject, ListBucket, ListBucketMultipartUploads, ListMultipartUploadParts,
    AbortMultipartUpload). It is given at CreateAccessPoint, or set by `PUT /v20180820/accesspoint/<name>/scope`,
    read by GET and removed by DELETE there. Only directory buckets' access points have one.
  - **Listing:** `GET /v20180820/accesspointfordirectory?directoryBucket=&maxResults=&nextToken=` gives
    `AccessPointList` > `AccessPoint` (Name, Bucket, Alias, AccessPointArn, BucketAccountId, NetworkOrigin), then
    `NextToken`.
  - **Through one:** the access point's name takes the bucket's place, for the object calls, HeadBucket,
    ListObjectsV2, ListMultipartUploads and CreateSession. Bucket calls are not taken. SigV4 only, and no anonymous
    requests. Both the bucket's policy and the access point's must allow a request.
  - **Not here:** VPC origins (NetworkOrigin Internet only) and tags.
- **What SDKs send to a custom endpoint, checked 18 Nov 2026** (boto3 1.42.97 against a stub):
  - **Data calls:** for `door--local-az1--xa-s3`, a CreateSession on the name (`GET /<name>?session`, or `/?session`
    to `<name>.<host>` with a host name), then the calls with its token, all signed for `s3express`. This is
    exactly what boto3 sends for a directory bucket.
  - **S3 Control calls:** CreateAccessPoint, GetAccessPoint, Put/Get/DeleteAccessPointScope,
    ListAccessPointsForDirectoryBuckets, PutAccessPointPolicy and DeleteAccessPoint go to the usual
    `/v20180820/...` paths with `x-amz-account-id`, signed for `s3express`.
- **What CosmoStore has:**
  - **Access points (ADR-0076):** kept in their bucket's access point record (`BUCKET_CONFIG_ACCESS_POINTS`), with
    a policy, a public-access block and the account. They are found by alias as the bucket and evaluated with the
    bucket's policy (`throughAccessPoint`).
  - **On a cluster (ADR-0078 §5):** their names and aliases are claimed in group 0.
  - **Directory buckets (ADR-0080):** CreateSession tokens name a bucket.

## Decision (proposed)

1. **Names and the record.**
   - A directory bucket's access point is named `<base>--<zone>--xa-s3`, with the base as above and the zone this
     server's (`--zone-id`), which is its bucket's.
   - Its alias is its name, and its ARN is `arn:aws:s3express:us-east-1:<account>:accesspoint/<name>`.
   - It is kept in its bucket's access point record, as a general-purpose bucket's are.
   - The record's access point encoding gains a version for the scope: prefixes, then a permission bitmask. A
     record of the earlier versions reads with no scope. Neither the journal nor the checkpoint changes format:
     the record is a `BucketConfig` value.
   - A `--xa-s3` name cannot name a general-purpose bucket's access point, and a directory bucket's access point
     must have one (InvalidRequest).
2. **S3 Control.** These keep their paths. A general-purpose access point is unchanged.
   - **CreateAccessPoint:** for a directory bucket of this zone. A `Scope` is checked as §3 says.
     `PublicAccessBlockConfiguration` is taken as ADR-0076 takes it. `VpcConfiguration` and `Tags` are
     NotImplemented. The answer gives the ARN and the alias.
   - **GetAccessPoint:** gives its fields with the `s3express` ARN.
   - **DeleteAccessPoint** and **Get/Put/DeleteAccessPointPolicy:** as ADR-0076's. A policy names the access point
     by the `arn:aws:s3express:…:accesspoint/<name>` resource, and `s3express:` actions.
   - **Get/Put/DeleteAccessPointScope:** a directory bucket's access point only (InvalidRequest for a
     general-purpose one). GET of none answers an empty `Scope`, since S3 names no error for it.
   - **ListAccessPointsForDirectoryBuckets:** this account's in name order, optionally only `directoryBucket`'s,
     `maxResults` (0 to 1,000) at a time with an opaque `NextToken`. ListAccessPoints leaves them out.
3. **The scope.**
   - **What it is:** up to 256 bytes of prefixes in all, and a set of the eight permissions. An unknown permission
     is InvalidRequest. A prefix may end in `*`, meaning "begins with", which is what a prefix without it means
     too.
   - **What it allows:** a request through the access point must have its permission in the set (when any are
     given), and its key in a prefix (when any are given). A listing's `prefix` must lie within one. Otherwise
     AccessDenied.
   - **The permission of each call:**

     | Calls | Permission |
     |---|---|
     | GetObject, HeadObject | GetObject |
     | GetObjectAttributes | GetObjectAttributes |
     | PutObject, CopyObject, CreateMultipartUpload, UploadPart(Copy), CompleteMultipartUpload | PutObject |
     | DeleteObject, each key of DeleteObjects | DeleteObject |
     | ListObjectsV2 | ListBucket |
     | ListMultipartUploads | ListBucketMultipartUploads |
     | ListParts | ListMultipartUploadParts |
     | AbortMultipartUpload | AbortMultipartUpload |
     | RenameObject (ADR-0081) | PutObject on the destination, DeleteObject on the source |

     HeadBucket and CreateSession need none. A copy's source is not read through an access point: requests
     cannot name one by ARN, and a source names its bucket.
4. **Requests through one.**
   - **Finding it:** a request whose bucket (path-style, or `<name>.<domain>`) is a directory access point's name is
     its bucket's, through it, as an alias is (ADR-0076 §2). The calls it takes are those of §Context.
   - **Authorization:** its policy and the bucket's are evaluated together (ADR-0076 §3). Requests must be signed;
     anonymous ones are AccessDenied.
   - **Sessions:** a CreateSession through an access point gives a session of the access point's name, not of its
     bucket. Such a session reaches the bucket only through that access point, and a session of the bucket does
     not reach it through an access point. So no session goes around a scope or a policy.
     `s3express:CreateSession` is decided by both policies, on each use as for a bucket's (ADR-0080 §4).
5. **On a cluster** (slice 2):
   - A directory access point's name, which is also its alias, is claimed in group 0 as an access point's is
     (ADR-0078 §5). The front routes `--xa-s3` names by that claim, and the scope calls and the directory listing as
     the other control calls (ListAccessPointsForDirectoryBuckets merged across shards, paged at the front).
6. **Tests.**
   - Unit tests of names, scopes and the permission of each call.
   - The S3 smoke: an access point made, a scope set, and requests through it inside and outside the scope, with
     sessions.
   - The cluster smoke: through every node.
   - Each SDK of the matrix: boto3, Go, JavaScript, Java, and .NET where it can address one.

## Slices

1. On `serve`: the record, S3 Control, the scope, and requests and sessions through an access point. Then the S3
   smoke and boto3.
2. On a cluster: the claims, the front's routing and the merged listing. Then the cluster smoke.
3. The rest of the SDK matrix.

## Rejected

- **Aliases unlike the name** (as general-purpose access points' `-s3alias`): AWS's alias is the name, and SDKs send
  the name.
- **A session of the bucket through an access point:** it would carry the bucket's rights past the access point's
  scope.
