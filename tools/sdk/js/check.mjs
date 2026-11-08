// The AWS SDK for JavaScript v3 against `cosmostore serve` (M3 SDK matrix). Run by tools/sdk/js.sh, which starts
// the server and sets AWS_ENDPOINT_URL and the credentials; the SDK (client-s3, lib-storage, s3-request-presigner,
// s3-presigned-post) is installed in JS_SDK_DIR.
import { createHash, randomBytes } from "node:crypto";
import {
  S3Client, CreateBucketCommand, PutObjectCommand, GetObjectCommand, HeadObjectCommand, CopyObjectCommand,
  DeleteObjectsCommand, DeleteBucketCommand, ListObjectsV2Command, paginateListObjectsV2, HeadBucketCommand,
} from "@aws-sdk/client-s3";
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
  check("put with " + algo, r, algo === "SHA1" ? "NotImplemented" : "no error");
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
process.exit(failed ? 1 : 0);
