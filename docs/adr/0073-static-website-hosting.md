# ADR-0073: Static website hosting (M7 item 2)

**Status:** accepted, 16 Nov 2026 (the owner: "Yes, accept ADR-0071 to 0077"); proposed the same day for M7 item 2 (ADR-0071), under the owner's standing go-ahead.

## Context

- S3 website hosting: `PutBucketWebsite` gives a bucket an index document, an error document, or a redirect of every
  request, and routing rules; a *website endpoint* (`<bucket>.s3-website-<region>.amazonaws.com`) serves it to
  anonymous browsers: GET and HEAD only, HTML errors, an index document for a folder, redirects. What a visitor may
  read is what the bucket's policy and ACLs let anyone read.
- CosmoStore serves S3 by path and by virtual host (`<bucket>.<domain>`), with bucket policies, ACLs and the
  public-access block for anonymous requests (ADR-0043 to ADR-0045).

## Decision

1. **The configuration** is a `BucketConfig` of kind 13 (checkpoint format 20): `PutBucketWebsite`,
   `GetBucketWebsite` (`NoSuchWebsiteConfiguration` without one), `DeleteBucketWebsite`. Supported: `IndexDocument`
   (`Suffix`), `ErrorDocument` (`Key`), `RedirectAllRequestsTo` (`HostName`, `Protocol`), and up to 50
   `RoutingRules`, each a `Condition` (`KeyPrefixEquals`, `HttpErrorCodeReturnedEquals`) and a `Redirect`
   (`HostName`, `Protocol`, `ReplaceKeyPrefixWith` or `ReplaceKeyWith`, `HttpRedirectCode`).
2. **The website endpoint** is a host name: `serve --website-domain <domain>` makes `<bucket>.<domain>` (any port) a
   website request on the S3 port. Such a request is anonymous whatever it carries:
   - GET and HEAD only (`405`);
   - `RedirectAllRequestsTo`: 301 to that host with the path;
   - a routing rule whose condition is a key prefix (no error code): its redirect, before anything is read;
   - the key empty or ending in `/`: the index document's suffix added;
   - the object read as an anonymous `GetObject` (the bucket's policy, ACLs, public-access block);
   - an object with `x-amz-website-redirect-location` (now kept, as `Cache-Control` is): 301 there;
   - not found: if `<key>/<index>` is there, 302 to `/<key>/`; a rule for the error code (404 or 403): its
     redirect; else the error document with the error's status, or a small HTML page naming the error.
3. **Not supported:** a custom domain without the `<bucket>.` form (S3's CNAME of a bucket named as its host), HTTPS
   on the website endpoint beyond what `serve` listens with, and a cluster: its S3 port refuses `PutBucketWebsite`
   for now.

## Consequences

- A bucket is a website once it has a configuration and anyone may read its objects (a policy granting
  `s3:GetObject` to `*`, and the public-access block allowing it).

## Rejected

- **A second listener for websites:** the host name already tells them apart, as S3's endpoints do.
