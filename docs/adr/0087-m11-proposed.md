# ADR-0087: M11, what comes after table maintenance (proposed)

**Status:** proposed, 19 Nov 2026. The owner: "propose M11". M10 (table maintenance, ADR-0086) closed the same day;
ADR-0085 §3 named identities the next candidate.

## Context

- **Who a request is today:**
  - **Keys:** every key is one account's: the credentials file's (`serve <credentials>`, reloaded on change,
    ADR-0050), each line a key and its secret. A key may do whatever no policy denies.
  - **Restricting a key:** the only way is a Deny naming it in every bucket's policy (ADR-0043), or in every table
    bucket's or table's (ADR-0084).
  - **Roles** (ADR-0075) come from `--roles-file`, each with one identity policy. AssumeRole sessions are narrowed
    by it on S3, and refused by S3 Tables (ADR-0083 §6).
  - **Policy principals** are keys (`arn:aws:iam:::user/<access key>`) or `*`.
  - `docs/compatibility.md` lists "users and accounts" as not done.
- **What a deployment with more than one application or team asks for:** a key that can read one bucket and nothing
  else, without a Deny in every other bucket. A user with two keys, rotated one at a time. A policy that names a user,
  not a key. AWS does this with IAM users, their access keys and their identity policies, decided with the
  resource's policy (one account: an identity Allow or a resource Allow, and no Deny in either).
- **What else is refused** (`docs/compatibility.md`):
  - lifecycle transitions;
  - ListMultipartUploads' `delimiter`;
  - SHA-1 checksums;
  - the object lock fields of a POST form;
  - SSE-KMS's encryption context;
  - HTTP/2 and SNI, which are CeeSafe.Web's.
- **Left by M10:** compaction, which needs a Parquet reader and writer and an engine's work in the server, and refs'
  `max-ref-age-ms`.
- **Left by ADR-0079 §5:** S3 Metadata tables, S3 Vectors, and an Iceberg engine in the server.

## Decision (proposed)

1. **M11 is one of these items**, each its own design ADR with a support matrix (what is done; what is refused, never
   silently ignored), on `serve` first and then a cluster.

   | # | Item | Done when |
   |---|---|---|
   | A | Identities: users, their keys, their identity policies | A users file names each user, its access keys and its identity policies, and is reloaded on change as the credentials file is (ADR-0050). A request is decided by the user's identity policies with the resource's policy, as AWS's IAM decides within one account: S3, S3 Express, S3 Tables, S3 Control. Policies may name `arn:aws:iam::<account>:user/<name>`. AssumeRole sessions are taken by S3 Tables, under their role's policies. A key restricted to one bucket's reads is refused everything else, through every SDK of the matrix, on `serve` and on a cluster. |
   | B | The long tail | Lifecycle transitions to a storage class kept here (`STANDARD_IA`, `GLACIER_IR` as names, the same bytes; or refused), ListMultipartUploads' `delimiter`, SHA-1 checksums, a POST form's object lock fields, SSE-KMS's encryption context. Each refused today becomes taken and matrix-tested. |
   | C | Compaction for S3 Tables | A Parquet reader and writer, enough for Iceberg's data files. A `binpack` strategy rewrites a partition's small files into files of `targetFileSizeMB`, committed as a `replace` snapshot. PyIceberg reads the same rows after. |

2. **The recommendation is A.** Every deployment past one application wants it, and the matrix's every service
   depends on it.
   - **Where it is not built from scratch:** it stands on what exists. The identity policy grammar and decision are
     roles' (ADR-0075 §2). The resource side is ADR-0043's and ADR-0084's, and the file and its reload are
     ADR-0050's.
   - **Its cost:** a users file format; each request resolving its key to a user; the decision combining identity
     and resource policies; principals by user; and AssumeRole in S3 Tables.
   - **No new journal record:** users are a file, like keys.
3. **B is the next candidate after A.** It is several small items, each a matrix row.
4. **C is not recommended now.** Parquet, and rewriting data files in the server, are the largest of the three. Its
   benefit is query speed, not storage or safety, and engines (Spark, PyIceberg's own `rewrite`) can compact through
   the catalog meanwhile.
5. **Not in M11:** the IAM API itself (CreateUser, AttachUserPolicy, CreateAccessKey: a service of its own; the file
   is the source of truth, as keys are now), S3 Metadata tables, S3 Vectors, HTTP/2 and SNI.

## For the owner to decide

- **Which item is M11:** A (recommended), B or C.
- **For A, where users are defined:**
  - a users file beside the credentials file (recommended: one more file, reloaded the same way);
  - users in the credentials file itself (one file, a new format of its lines);
  - or the IAM API's calls (stored in the store; a larger item).

## Consequences

- One design ADR follows the choice, with its slices.
- For A: the credentials file stays as it is. A key the users file does not name is the account's, as every key is
  now, so existing deployments change nothing until they write a users file.
