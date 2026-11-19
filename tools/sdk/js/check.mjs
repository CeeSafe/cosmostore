// The AWS SDK for JavaScript v3 against `cosmostore serve` (M3 SDK matrix). Run by tools/sdk/js.sh, which starts
// the server and sets AWS_ENDPOINT_URL and the credentials; the SDK (client-s3, lib-storage, s3-request-presigner,
// s3-presigned-post, and for M7 client-s3-control and client-sts) is installed in JS_SDK_DIR.
import { createHash, randomBytes } from "node:crypto";
import http from "node:http";
import { gunzipSync } from "node:zlib";
import {
  S3Client, CreateBucketCommand, ListBucketsCommand, PutObjectCommand, GetObjectCommand, HeadObjectCommand, CopyObjectCommand,
  DeleteObjectsCommand, DeleteBucketCommand, ListObjectsV2Command, paginateListObjectsV2, HeadBucketCommand,
  PutBucketLoggingCommand, GetBucketLoggingCommand, PutBucketWebsiteCommand, GetBucketWebsiteCommand,
  DeleteBucketWebsiteCommand, PutBucketPolicyCommand, DeleteBucketPolicyCommand, PutBucketInventoryConfigurationCommand,
  GetBucketInventoryConfigurationCommand, ListBucketInventoryConfigurationsCommand,
  DeleteBucketInventoryConfigurationCommand, PutBucketVersioningCommand, PutBucketReplicationCommand,
  GetBucketReplicationCommand, DeleteBucketReplicationCommand, ListDirectoryBucketsCommand, DeleteObjectCommand,
} from "@aws-sdk/client-s3";
import {
  GetAccessPointScopeCommand, ListAccessPointsForDirectoryBucketsCommand,
  S3ControlClient, CreateAccessPointCommand, GetAccessPointCommand, ListAccessPointsCommand, DeleteAccessPointCommand,
} from "@aws-sdk/client-s3-control";
import { STSClient, GetSessionTokenCommand, AssumeRoleCommand } from "@aws-sdk/client-sts";
import {
  S3TablesClient, CreateTableBucketCommand, ListTableBucketsCommand, CreateNamespaceCommand, CreateTableCommand,
  GetTableCommand, UpdateTableMetadataLocationCommand, RenameTableCommand, ListTablesCommand, DeleteTableCommand,
  DeleteNamespaceCommand, DeleteTableBucketCommand, PutTableBucketMaintenanceConfigurationCommand,
  GetTableBucketMaintenanceConfigurationCommand, GetTableMaintenanceConfigurationCommand,
  GetTableMaintenanceJobStatusCommand,
} from "@aws-sdk/client-s3tables";
import { Upload } from "@aws-sdk/lib-storage";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { createPresignedPost } from "@aws-sdk/s3-presigned-post";

const endpoint = process.env.AWS_ENDPOINT_URL;
let failed = false;
const check = (name, got, want) => {
  if (JSON.stringify(got) === JSON.stringify(want)) console.log("ok  ", name);
  else { console.log(`FAIL ${name}: expected [${JSON.stringify(want)}], got [${JSON.stringify(got)}]`); failed = true; }
};
const codeOf = async (p) => { try { await p; return "no error"; } catch (e) { return e.name; } };
const bytes = async (body) => Buffer.from(await body.transformToByteArray());

const client = (pathStyle) => new S3Client({
  endpoint: pathStyle ? endpoint : endpoint.replace("127.0.0.1", "localhost"), forcePathStyle: pathStyle,
  region: "us-east-1", maxAttempts: 1,
});
const s3 = client(true);
const Bucket = "js-sdk-test";
await s3.send(new CreateBucketCommand({ Bucket }));
check("create twice", await codeOf(s3.send(new CreateBucketCommand({ Bucket }))), "BucketAlreadyOwnedByYou");

const body = randomBytes(300000);
const put = await s3.send(new PutObjectCommand({ Bucket, Key: "o/plain", Body: body, ContentType: "x/y", Metadata: { k: "v" } }));
check("put ETag", put.ETag, `"${createHash("md5").update(body).digest("hex")}"`);
for (const algo of ["CRC32", "CRC32C", "SHA256", "SHA1"]) {
  const r = await codeOf(s3.send(new PutObjectCommand({ Bucket, Key: "o/" + algo, Body: body, ChecksumAlgorithm: algo })));
  check("put with " + algo, r, "no error"); // SHA-1 too, since ADR-0090 §4
}
const got = await s3.send(new GetObjectCommand({ Bucket, Key: "o/plain" }));
check("get", (await bytes(got.Body)).equals(body), true);
check("content type and metadata", [got.ContentType, got.Metadata], ["x/y", { k: "v" }]);
const ranged = await s3.send(new GetObjectCommand({ Bucket, Key: "o/plain", Range: "bytes=5-9" }));
check("range", (await bytes(ranged.Body)).equals(body.subarray(5, 10)), true);
check("NoSuchKey", await codeOf(s3.send(new GetObjectCommand({ Bucket, Key: "nope" }))), "NoSuchKey");
check("head NotFound", await codeOf(s3.send(new HeadObjectCommand({ Bucket, Key: "nope" }))), "NotFound");

for (let i = 0; i < 23; i++) await s3.send(new PutObjectCommand({ Bucket, Key: `l/${String(i).padStart(2, "0")}`, Body: Buffer.alloc(0) }));
let n = 0;
for await (const page of paginateListObjectsV2({ client: s3, pageSize: 5 }, { Bucket, Prefix: "l/" })) n += page.Contents.length;
check("list paginator", n, 23);

const big = randomBytes(13 << 20);
await new Upload({ client: s3, params: { Bucket, Key: "m/big", Body: big }, partSize: 5 << 20, queueSize: 3 }).done();
const head = await s3.send(new HeadObjectCommand({ Bucket, Key: "m/big" }));
check("multipart ETag", head.ETag.endsWith('-3"'), true);
check("multipart bytes", (await bytes((await s3.send(new GetObjectCommand({ Bucket, Key: "m/big" }))).Body)).equals(big), true);
await s3.send(new CopyObjectCommand({ Bucket, Key: "o/copy", CopySource: `${Bucket}/o/plain` }));
check("copy", (await bytes((await s3.send(new GetObjectCommand({ Bucket, Key: "o/copy" }))).Body)).equals(body), true);

const url = await getSignedUrl(s3, new GetObjectCommand({ Bucket, Key: "o/plain" }), { expiresIn: 60 });
check("presigned GET", Buffer.from(await (await fetch(url)).arrayBuffer()).equals(body), true);
// The presigner signs a CRC32 of the empty body into the URL, so S3 refuses any other body: BadDigest, here too.
const hoisted = await getSignedUrl(s3, new PutObjectCommand({ Bucket, Key: "p/put" }), { expiresIn: 60 });
const refused = await fetch(hoisted, { method: "PUT", body: "presigned" });
check("presigned PUT with the SDK's empty-body checksum", [refused.status, (await refused.text()).includes("BadDigest")], [400, true]);
// The SDK's documented fix: no checksum unless one is required.
const plain = new S3Client({ endpoint, forcePathStyle: true, region: "us-east-1", requestChecksumCalculation: "WHEN_REQUIRED" });
const putUrl = await getSignedUrl(plain, new PutObjectCommand({ Bucket, Key: "p/put" }), { expiresIn: 60 });
check("presigned PUT", (await fetch(putUrl, { method: "PUT", body: "presigned" })).status, 200);
check("presigned PUT stored", (await bytes((await s3.send(new GetObjectCommand({ Bucket, Key: "p/put" }))).Body)).toString(), "presigned");

// POST object with a SigV4 policy (ADR-0018), as a browser form sends it.
const post = await createPresignedPost(s3, {
  Bucket, Key: "post/${filename}", Expires: 60,
  Conditions: [["starts-with", "$key", "post/"], ["content-length-range", 1, 1024]],
  Fields: { "Content-Type": "text/plain" },
});
const form = new FormData();
for (const [k, val] of Object.entries(post.fields)) form.append(k, val);
form.append("file", new Blob(["from a form"], { type: "text/plain" }), "form.txt");
check("presigned POST", (await fetch(post.url, { method: "POST", body: form })).status, 204);
check("presigned POST stored", (await bytes((await s3.send(new GetObjectCommand({ Bucket, Key: "post/form.txt" }))).Body)).toString(), "from a form");
const tooBig = new FormData();
for (const [k, val] of Object.entries(post.fields)) tooBig.append(k, val);
tooBig.append("file", new Blob(["x".repeat(2000)]), "big.txt");
check("presigned POST too large", (await fetch(post.url, { method: "POST", body: tooBig })).status, 400);

const v = client(false);
await v.send(new PutObjectCommand({ Bucket, Key: "v/hosted", Body: "virtual" }));
check("virtual-host", (await bytes((await v.send(new GetObjectCommand({ Bucket, Key: "v/hosted" }))).Body)).toString(), "virtual");

const keys = [];
for await (const page of paginateListObjectsV2({ client: s3 }, { Bucket })) keys.push(...page.Contents.map((o) => ({ Key: o.Key })));
const del = await s3.send(new DeleteObjectsCommand({ Bucket, Delete: { Objects: keys } }));
check("delete objects", del.Deleted.length, keys.length);
check("bucket empty", (await s3.send(new ListObjectsV2Command({ Bucket }))).KeyCount, 0);
await s3.send(new DeleteBucketCommand({ Bucket }));
check("bucket deleted", await codeOf(s3.send(new HeadBucketCommand({ Bucket }))), "NotFound");

// M7 (ADR-0072 to ADR-0077): each item's configuration calls and what each does. common.sh starts serve with access
// logs every 2 s, a 3 s inventory day, websites under web.localhost and a role "reader" of sdk-m7.
const until = async (fn, seconds = 15) => {
  const end = Date.now() + seconds * 1000;
  while (Date.now() < end) {
    const got = await fn();
    if (got) return got;
    await new Promise((r) => setTimeout(r, 250));
  }
  return null;
};
const keysUnder = async (B, Prefix) => ((await s3.send(new ListObjectsV2Command({ Bucket: B, Prefix }))).Contents ?? []).map((o) => o.Key);
const read = async (c, B, Key) => {
  try { return (await bytes((await c.send(new GetObjectCommand({ Bucket: B, Key }))).Body)).toString(); } catch (e) { return e.name; }
};
const M7 = "sdk-m7", LOGS = "sdk-m7-logs", ACCOUNT = "000000000000";
for (const B of [M7, LOGS]) await s3.send(new CreateBucketCommand({ Bucket: B }));
await s3.send(new PutObjectCommand({ Bucket: M7, Key: "index.html", Body: "the index", ContentType: "text/html" }));
await s3.send(new PutObjectCommand({ Bucket: M7, Key: "error.html", Body: "the error page", ContentType: "text/html" }));

// Access logs (ADR-0072).
const loggingOn = { TargetBucket: LOGS, TargetPrefix: "access/" };
await s3.send(new PutBucketLoggingCommand({ Bucket: M7, BucketLoggingStatus: { LoggingEnabled: loggingOn } }));
check("GetBucketLogging", (await s3.send(new GetBucketLoggingCommand({ Bucket: M7 }))).LoggingEnabled, loggingOn);
check("logging to a bucket that is not there", await codeOf(s3.send(new PutBucketLoggingCommand({ Bucket: M7, BucketLoggingStatus: {
  LoggingEnabled: { TargetBucket: "sdk-nowhere", TargetPrefix: "x/" } } }))), "InvalidTargetBucketForLogging");
await s3.send(new PutObjectCommand({ Bucket: M7, Key: "logged.txt", Body: "logged" }));
check("the PUT's line in a log object", await until(async () => {
  for (const k of await keysUnder(LOGS, "access/")) if ((await read(s3, LOGS, k)).includes("REST.PUT.OBJECT logged.txt")) return true;
  return false;
}), true);
await s3.send(new PutBucketLoggingCommand({ Bucket: M7, BucketLoggingStatus: {} }));
check("logging off", (await s3.send(new GetBucketLoggingCommand({ Bucket: M7 }))).LoggingEnabled ?? null, null);

// Website hosting (ADR-0073), through <bucket>.web.localhost, with a policy that lets anyone read.
const site = { IndexDocument: { Suffix: "index.html" }, ErrorDocument: { Key: "error.html" } };
await s3.send(new PutBucketWebsiteCommand({ Bucket: M7, WebsiteConfiguration: site }));
const ws = await s3.send(new GetBucketWebsiteCommand({ Bucket: M7 }));
check("GetBucketWebsite", [ws.IndexDocument, ws.ErrorDocument], [site.IndexDocument, site.ErrorDocument]);
await s3.send(new PutBucketPolicyCommand({ Bucket: M7, Policy: JSON.stringify({ Version: "2012-10-17", Statement: [{ Effect: "Allow",
  Principal: "*", Action: "s3:GetObject", Resource: `arn:aws:s3:::${M7}/*` }] }) }));
const port = endpoint.slice(endpoint.lastIndexOf(":") + 1);
const page = (path) => new Promise((resolve) => {
  // fetch() will not send another Host; node:http will.
  http.get({ host: "127.0.0.1", port, path, headers: { Host: `${M7}.web.localhost:${port}` } }, (res) => {
    let text = "";
    res.on("data", (d) => { text += d; });
    res.on("end", () => resolve([res.statusCode, text]));
  });
});
check("the site's index", await page("/"), [200, "the index"]);
check("the site's error document", await page("/no-such-page"), [404, "the error page"]);
await s3.send(new DeleteBucketWebsiteCommand({ Bucket: M7 }));
check("the website deleted", await codeOf(s3.send(new GetBucketWebsiteCommand({ Bucket: M7 }))), "NoSuchWebsiteConfiguration");
await s3.send(new DeleteBucketPolicyCommand({ Bucket: M7 }));

// Inventory (ADR-0074): a daily CSV report into the logs bucket; a day is 3 s here.
const destination = { S3BucketDestination: { Bucket: `arn:aws:s3:::${LOGS}`, Format: "CSV", Prefix: "inv" } };
const inventory = (Id, Destination) => ({ Bucket: M7, Id, InventoryConfiguration: { Id, IsEnabled: true, IncludedObjectVersions: "Current",
  Schedule: { Frequency: "Daily" }, Destination } });
await s3.send(new PutBucketInventoryConfigurationCommand(inventory("daily", destination)));
const inv = (await s3.send(new GetBucketInventoryConfigurationCommand({ Bucket: M7, Id: "daily" }))).InventoryConfiguration;
check("GetBucketInventoryConfiguration", [inv.Id, inv.IsEnabled, inv.Schedule, inv.Destination], ["daily", true, { Frequency: "Daily" }, destination]);
check("ListBucketInventoryConfigurations", (await s3.send(new ListBucketInventoryConfigurationsCommand({ Bucket: M7 })))
  .InventoryConfigurationList.map((c) => c.Id), ["daily"]);
check("an account id is not done, not dropped", await codeOf(s3.send(new PutBucketInventoryConfigurationCommand(inventory("acct",
  { S3BucketDestination: { ...destination.S3BucketDestination, AccountId: "111122223333" } })))), "NotImplemented");
const manifest = await until(async () => (await keysUnder(LOGS, "inv/")).find((k) => k.endsWith("manifest.json")), 20);
check("a report's manifest", Boolean(manifest), true);
if (manifest) {
  const files = JSON.parse(await read(s3, LOGS, manifest)).files;
  const csv = gunzipSync(await bytes((await s3.send(new GetObjectCommand({ Bucket: LOGS, Key: files[0].key }))).Body)).toString();
  const keysListed = csv.trim().split("\n").map((line) => JSON.parse(`[${line}]`)[1]).sort();
  check("its CSV has every object", keysListed, ["error.html", "index.html", "logged.txt"]);
}
await s3.send(new DeleteBucketInventoryConfigurationCommand({ Bucket: M7, Id: "daily" }));
check("the inventory deleted", await codeOf(s3.send(new GetBucketInventoryConfigurationCommand({ Bucket: M7, Id: "daily" }))), "NoSuchConfiguration");

// STS (ADR-0075): a session token, and the role "reader", sign S3 requests.
const sts = new STSClient({ endpoint, region: "us-east-1", maxAttempts: 1 });
const as = (c) => new S3Client({ endpoint, forcePathStyle: true, region: "us-east-1", maxAttempts: 1,
  credentials: { accessKeyId: c.AccessKeyId, secretAccessKey: c.SecretAccessKey, sessionToken: c.SessionToken } });
const session = (await sts.send(new GetSessionTokenCommand({ DurationSeconds: 900 }))).Credentials;
check("GetSessionToken gives an ASIA key", session.AccessKeyId.slice(0, 4), "ASIA");
check("the session reads", await read(as(session), M7, "logged.txt"), "logged");
const reader = as((await sts.send(new AssumeRoleCommand({ RoleArn: `arn:aws:iam::${ACCOUNT}:role/reader`, RoleSessionName: "js" }))).Credentials);
check("the role reads", await read(reader, M7, "logged.txt"), "logged");
check("the role does not write", await codeOf(reader.send(new PutObjectCommand({ Bucket: M7, Key: "no", Body: "no" }))), "AccessDenied");
check("nor read another bucket", await codeOf(reader.send(new ListObjectsV2Command({ Bucket: LOGS }))), "AccessDenied");
check("policy ARNs are not done, not dropped", await codeOf(sts.send(new AssumeRoleCommand({ RoleArn: `arn:aws:iam::${ACCOUNT}:role/reader`,
  RoleSessionName: "arns", PolicyArns: [{ arn: "arn:aws:iam::aws:policy/ReadOnlyAccess" }] }))), "NotImplemented");

// Access Points (ADR-0076): S3 Control puts the account in the host (`<account>.localhost`); a request by ARN goes
// to `<name>-<account>.localhost`.
const ctl = new S3ControlClient({ endpoint: endpoint.replace("127.0.0.1", "localhost"), region: "us-east-1", maxAttempts: 1 });
const made = await ctl.send(new CreateAccessPointCommand({ AccountId: ACCOUNT, Name: "sdk-ap", Bucket: M7 }));
check("CreateAccessPoint gives an alias", (made.Alias ?? "").endsWith("-s3alias"), true);
const ap = await ctl.send(new GetAccessPointCommand({ AccountId: ACCOUNT, Name: "sdk-ap" }));
check("GetAccessPoint", [ap.Bucket, ap.NetworkOrigin], [M7, "Internet"]);
check("ListAccessPoints", (await ctl.send(new ListAccessPointsCommand({ AccountId: ACCOUNT, Bucket: M7 }))).AccessPointList.map((a) => a.Name), ["sdk-ap"]);
check("a name twice", await codeOf(ctl.send(new CreateAccessPointCommand({ AccountId: ACCOUNT, Name: "sdk-ap", Bucket: M7 }))),
  "AccessPointAlreadyOwnedByYou");
await s3.send(new PutObjectCommand({ Bucket: made.Alias, Key: "ap/door.txt", Body: "through a door" }));
check("a write by its alias lands in its bucket", await read(s3, M7, "ap/door.txt"), "through a door");
check("a read by its ARN", await read(client(false), `arn:aws:s3:us-east-1:${ACCOUNT}:accesspoint/sdk-ap`, "ap/door.txt"), "through a door");
await ctl.send(new DeleteAccessPointCommand({ AccountId: ACCOUNT, Name: "sdk-ap" }));
check("the access point deleted", await codeOf(ctl.send(new GetAccessPointCommand({ AccountId: ACCOUNT, Name: "sdk-ap" }))), "NoSuchAccessPoint");

// Replication (ADR-0077): a new version copied to another bucket with its version id and ETag.
const RS = "sdk-rsrc", RD = "sdk-rdst";
for (const B of [RS, RD]) {
  await s3.send(new CreateBucketCommand({ Bucket: B }));
  await s3.send(new PutBucketVersioningCommand({ Bucket: B, VersioningConfiguration: { Status: "Enabled" } }));
}
const rule = (ID) => ({ ID, Priority: 1, Status: "Enabled", Filter: { Prefix: "" }, DeleteMarkerReplication: { Status: "Enabled" },
  Destination: { Bucket: `arn:aws:s3:::${RD}` } });
const replication = (Rules) => ({ Bucket: RS, ReplicationConfiguration: { Role: `arn:aws:iam::${ACCOUNT}:role/r`, Rules } });
check("one priority twice", await codeOf(s3.send(new PutBucketReplicationCommand(replication([rule("all"), rule("again")])))), "InvalidArgument");
await s3.send(new PutBucketReplicationCommand(replication([rule("all")])));
check("GetBucketReplication", (await s3.send(new GetBucketReplicationCommand({ Bucket: RS }))).ReplicationConfiguration.Rules[0].Destination.Bucket,
  `arn:aws:s3:::${RD}`);
const src = await s3.send(new PutObjectCommand({ Bucket: RS, Key: "r/one.txt", Body: "replicate me" }));
check("replicated", await until(async () => (await s3.send(new HeadObjectCommand({ Bucket: RS, Key: "r/one.txt" }))).ReplicationStatus === "COMPLETED"), true);
const replica = await s3.send(new HeadObjectCommand({ Bucket: RD, Key: "r/one.txt" }));
check("the replica keeps its version id and ETag", [replica.VersionId, replica.ETag], [src.VersionId, src.ETag]);
check("and is a replica", replica.ReplicationStatus, "REPLICA");
await s3.send(new DeleteBucketReplicationCommand({ Bucket: RS }));
check("the replication deleted", await codeOf(s3.send(new GetBucketReplicationCommand({ Bucket: RS }))), "ReplicationConfigurationNotFoundError");

// Directory buckets (ADR-0080): with the SDK's sessions (CreateSession) and with them off. ListDirectoryBuckets takes no
// session, and is listed with sessions off.
const DIR = "sdk--local-az1--x-s3";
const lister = new S3Client({ endpoint, forcePathStyle: true, region: "us-east-1", maxAttempts: 1, disableS3ExpressSessionAuth: true });
for (const sessions of [true, false]) {
  const how = sessions ? " (sessions)" : " (sessions off)";
  const d = new S3Client({ endpoint, forcePathStyle: true, region: "us-east-1", maxAttempts: 1, disableS3ExpressSessionAuth: !sessions });
  const made = await d.send(new CreateBucketCommand({ Bucket: DIR, CreateBucketConfiguration: {
    Location: { Type: "AvailabilityZone", Name: "local-az1" }, Bucket: { DataRedundancy: "SingleAvailabilityZone", Type: "Directory" } } }));
  check("create a directory bucket" + how, (made.BucketArn ?? "").endsWith(":bucket/" + DIR), true);
  check("ListDirectoryBuckets" + how, (await lister.send(new ListDirectoryBucketsCommand({}))).Buckets.map((b) => b.Name), [DIR]);
  const body = "in a directory";
  const put = await d.send(new PutObjectCommand({ Bucket: DIR, Key: "a/b.txt", Body: body }));
  check("an ETag that is not the MD5" + how, put.ETag !== `"${createHash("md5").update(body).digest("hex")}"`, true);
  check("GET with If-Match" + how, (await bytes((await d.send(new GetObjectCommand({ Bucket: DIR, Key: "a/b.txt", IfMatch: put.ETag }))).Body)).toString(), body);
  check("listed" + how, (await d.send(new ListObjectsV2Command({ Bucket: DIR, Prefix: "a/" }))).Contents.map((o) => o.Key), ["a/b.txt"]);
  await new Upload({ client: d, params: { Bucket: DIR, Key: "big/m.bin", Body: randomBytes(12 << 20) }, partSize: 5 << 20, queueSize: 2 }).done();
  check("a multipart ETag without -N" + how, (await d.send(new HeadObjectCommand({ Bucket: DIR, Key: "big/m.bin" }))).ETag.includes("-"), false);
  check("no versioning" + how, await codeOf(d.send(new PutBucketVersioningCommand({ Bucket: DIR, VersioningConfiguration: { Status: "Enabled" } }))), "NotImplemented");
  for (const Key of ["a/b.txt", "big/m.bin"]) await d.send(new DeleteObjectCommand({ Bucket: DIR, Key }));
  await d.send(new DeleteBucketCommand({ Bucket: DIR }));
  check("deleted" + how, (await lister.send(new ListDirectoryBucketsCommand({}))).Buckets ?? [], []);
}

// A directory bucket's access point (ADR-0082): made with a scope, requests through it with the SDK's sessions.
{
  const APB = "sdk4--local-az1--x-s3", AP = "sdkjs--local-az1--xa-s3";
  const d = new S3Client({ endpoint, forcePathStyle: true, region: "us-east-1", maxAttempts: 1 });
  await d.send(new CreateBucketCommand({ Bucket: APB, CreateBucketConfiguration: {
    Location: { Type: "AvailabilityZone", Name: "local-az1" }, Bucket: { DataRedundancy: "SingleAvailabilityZone", Type: "Directory" } } }));
  const made = await ctl.send(new CreateAccessPointCommand({ AccountId: ACCOUNT, Name: AP, Bucket: APB,
    Scope: { Prefixes: ["pub/"], Permissions: ["GetObject", "PutObject"] } }));
  check("directory access point: its alias is its name", made.Alias, AP);
  const scope = (await ctl.send(new GetAccessPointScopeCommand({ AccountId: ACCOUNT, Name: AP }))).Scope;
  check("GetAccessPointScope", [scope.Prefixes, scope.Permissions], [["pub/"], ["GetObject", "PutObject"]]);
  check("ListAccessPointsForDirectoryBuckets", (await ctl.send(new ListAccessPointsForDirectoryBucketsCommand({ AccountId: ACCOUNT,
    DirectoryBucket: APB }))).AccessPointList.map((a) => a.Name), [AP]);
  await d.send(new PutObjectCommand({ Bucket: AP, Key: "pub/a.txt", Body: "through" }));
  check("a GET through it", (await bytes((await d.send(new GetObjectCommand({ Bucket: AP, Key: "pub/a.txt" }))).Body)).toString(), "through");
  check("a key outside its scope", await codeOf(d.send(new GetObjectCommand({ Bucket: AP, Key: "other/a.txt" }))), "AccessDenied");
  check("a permission outside its scope", await codeOf(d.send(new DeleteObjectCommand({ Bucket: AP, Key: "pub/a.txt" }))), "AccessDenied");
  await ctl.send(new DeleteAccessPointCommand({ AccountId: ACCOUNT, Name: AP }));
  await d.send(new DeleteObjectCommand({ Bucket: APB, Key: "pub/a.txt" }));
  await d.send(new DeleteBucketCommand({ Bucket: APB }));
}
// S3 Tables (ADR-0083): table buckets, namespaces and tables, and the metadata location's compare-and-set.
{
  const t = new S3TablesClient({ endpoint, region: "us-east-1", maxAttempts: 1 });
  const s = new S3Client({ endpoint, forcePathStyle: true, region: "us-east-1", maxAttempts: 1 });
  const arn = (await t.send(new CreateTableBucketCommand({ name: "sdk-js-tables" }))).arn;
  check("CreateTableBucket", arn, `arn:aws:s3tables:us-east-1:${ACCOUNT}:bucket/sdk-js-tables`);
  check("ListTableBuckets", (await t.send(new ListTableBucketsCommand({}))).tableBuckets.map((b) => b.name), ["sdk-js-tables"]);
  await t.send(new CreateNamespaceCommand({ tableBucketARN: arn, namespace: ["sales"] }));
  const made = await t.send(new CreateTableCommand({ tableBucketARN: arn, namespace: "sales", name: "orders", format: "ICEBERG" }));
  const got = await t.send(new GetTableCommand({ tableArn: made.tableARN }));
  check("GetTable by its ARN", got.name, "orders");
  const wh = got.warehouseLocation;
  const [wb, ...rest] = wh.slice(5).split("/");
  await s.send(new PutObjectCommand({ Bucket: wb, Key: rest.join("/") + "/metadata/00001-j.metadata.json", Body: "{}" }));
  const moved = await t.send(new UpdateTableMetadataLocationCommand({ tableBucketARN: arn, namespace: "sales", name: "orders",
    versionToken: got.versionToken, metadataLocation: wh + "/metadata/00001-j.metadata.json" }));
  check("UpdateTableMetadataLocation", moved.metadataLocation, wh + "/metadata/00001-j.metadata.json");
  check("a stale versionToken", await codeOf(t.send(new UpdateTableMetadataLocationCommand({ tableBucketARN: arn, namespace: "sales",
    name: "orders", versionToken: got.versionToken, metadataLocation: wh + "/metadata/00002-j.metadata.json" }))), "ConflictException");
  await t.send(new RenameTableCommand({ tableBucketARN: arn, namespace: "sales", name: "orders", newName: "orders2" }));
  check("RenameTable", (await t.send(new ListTablesCommand({ tableBucketARN: arn }))).tables.map((x) => x.name), ["orders2"]);
  // Maintenance (ADR-0086): a table bucket's configuration put and read back; compaction is not done.
  await t.send(new PutTableBucketMaintenanceConfigurationCommand({ tableBucketARN: arn, type: "icebergUnreferencedFileRemoval",
    value: { status: "enabled", settings: { icebergUnreferencedFileRemoval: { unreferencedDays: 4, nonCurrentDays: 9 } } } }));
  const bm = await t.send(new GetTableBucketMaintenanceConfigurationCommand({ tableBucketARN: arn }));
  check("GetTableBucketMaintenanceConfiguration",
    bm.configuration.icebergUnreferencedFileRemoval.settings.icebergUnreferencedFileRemoval.unreferencedDays, 4);
  const tm = await t.send(new GetTableMaintenanceConfigurationCommand({ tableBucketARN: arn, namespace: "sales", name: "orders2" }));
  check("GetTableMaintenanceConfiguration: compaction off", tm.configuration.icebergCompaction.status, "disabled");
  const js = await t.send(new GetTableMaintenanceJobStatusCommand({ tableBucketARN: arn, namespace: "sales", name: "orders2" }));
  check("GetTableMaintenanceJobStatus", js.status.icebergCompaction.status, "Disabled");
  await t.send(new DeleteTableCommand({ tableBucketARN: arn, namespace: "sales", name: "orders2" }));
  await t.send(new DeleteNamespaceCommand({ tableBucketARN: arn, namespace: "sales" }));
  await t.send(new DeleteTableBucketCommand({ tableBucketARN: arn }));
  check("DeleteTableBucket", (await t.send(new ListTableBucketsCommand({}))).tableBuckets ?? [], []);
}

// Users (ADR-0088): a user's key reads what its identity policy allows, and nothing else.
{
  const account = new S3Client({ endpoint, forcePathStyle: true, region: "us-east-1", maxAttempts: 1 });
  await account.send(new CreateBucketCommand({ Bucket: "sdk-js-users" }));
  await account.send(new PutObjectCommand({ Bucket: "sdk-js-users", Key: "a", Body: "read me" }));
  const user = new S3Client({ endpoint, forcePathStyle: true, region: "us-east-1", maxAttempts: 1,
    credentials: { accessKeyId: "AKIASDKUSER000000001", secretAccessKey: "sdkuser/secret/0123456789abcdefgh" } });
  const got = await user.send(new GetObjectCommand({ Bucket: "sdk-js-users", Key: "a" }));
  check("a user reads", await got.Body.transformToString(), "read me");
  check("a user writes nothing", await codeOf(user.send(new PutObjectCommand({ Bucket: "sdk-js-users", Key: "b", Body: "x" }))), "AccessDenied");
  check("nor lists every bucket", await codeOf(user.send(new ListBucketsCommand({}))), "AccessDenied");
  await account.send(new DeleteObjectCommand({ Bucket: "sdk-js-users", Key: "a" }));
  await account.send(new DeleteBucketCommand({ Bucket: "sdk-js-users" }));
}
// The long tail (ADR-0090): storage classes recorded, or refused.
{
  const s3t = new S3Client({ endpoint, forcePathStyle: true, region: "us-east-1", maxAttempts: 1 });
  await s3t.send(new CreateBucketCommand({ Bucket: "sdk-js-tail" }));
  await s3t.send(new PutObjectCommand({ Bucket: "sdk-js-tail", Key: "ia", Body: "x", StorageClass: "STANDARD_IA" }));
  check("a storage class recorded", (await s3t.send(new HeadObjectCommand({ Bucket: "sdk-js-tail", Key: "ia" }))).StorageClass, "STANDARD_IA");
  check("an archive class refused", await codeOf(s3t.send(new PutObjectCommand({ Bucket: "sdk-js-tail", Key: "g", Body: "x", StorageClass: "GLACIER" }))), "InvalidStorageClass");
  await s3t.send(new DeleteObjectCommand({ Bucket: "sdk-js-tail", Key: "ia" }));
  await s3t.send(new DeleteBucketCommand({ Bucket: "sdk-js-tail" }));
}
process.exit(failed ? 1 : 0);
