// The AWS SDK for .NET against `cosmostore serve` (M3 SDK matrix). Run by tools/sdk/dotnet.sh, which starts the
// server and sets AWS_ENDPOINT_URL and the credentials. Prints one line per check; exit status 1 if any fails.
using System.Security.Cryptography;
using Amazon.S3;
using Amazon.S3.Model;
using Amazon.S3.Transfer;

var failed = false;
void Check(string name, object got, object want)
{
    if (Equals(got, want)) { Console.WriteLine("ok   " + name); }
    else { Console.WriteLine($"FAIL {name}: expected [{want}], got [{got}]"); failed = true; }
}
async Task<string> CodeOf(Func<Task> f)
{
    try { await f(); return "no error"; }
    catch (AmazonS3Exception e) { return e.ErrorCode ?? ((int)e.StatusCode).ToString(); }
}
static string Md5(byte[] data) => "\"" + Convert.ToHexString(MD5.HashData(data)).ToLowerInvariant() + "\"";
static async Task<byte[]> ReadAll(GetObjectResponse r)
{
    using var ms = new MemoryStream();
    await r.ResponseStream.CopyToAsync(ms);
    return ms.ToArray();
}

var endpoint = Environment.GetEnvironmentVariable("AWS_ENDPOINT_URL");
AmazonS3Client Client(bool pathStyle) => new AmazonS3Client(new AmazonS3Config
{
    ServiceURL = pathStyle ? endpoint : endpoint.Replace("127.0.0.1", "localhost"),
    ForcePathStyle = pathStyle,
    AuthenticationRegion = "us-east-1",
    MaxErrorRetry = 0,
});
var s3 = Client(true);
var b = "dotnet-sdk-test";
await s3.PutBucketAsync(b);
Check("create twice", await CodeOf(() => s3.PutBucketAsync(b)), "BucketAlreadyOwnedByYou");

var body = new byte[300000];
new Random(1).NextBytes(body);
var put = await s3.PutObjectAsync(new PutObjectRequest
{
    BucketName = b, Key = "o/plain", InputStream = new MemoryStream(body), ContentType = "x/y",
    Metadata = { ["k"] = "v" },
});
Check("put ETag", put.ETag, Md5(body));
foreach (var algo in new[] { ChecksumAlgorithm.CRC32, ChecksumAlgorithm.CRC32C, ChecksumAlgorithm.SHA256, ChecksumAlgorithm.CRC64NVME })
{
    var key = "o/" + algo.Value;
    var outcome = await CodeOf(() => s3.PutObjectAsync(new PutObjectRequest
    {
        BucketName = b, Key = key, InputStream = new MemoryStream(body), ChecksumAlgorithm = algo,
    }));
    Check("put with " + algo.Value, outcome, "no error");
}
var got = await s3.GetObjectAsync(b, "o/plain");
Check("get", (await ReadAll(got)).SequenceEqual(body), true);
Check("content type and metadata", got.Headers.ContentType + " " + got.Metadata["k"], "x/y v");
var ranged = await s3.GetObjectAsync(new GetObjectRequest { BucketName = b, Key = "o/plain", ByteRange = new ByteRange(5, 9) });
Check("range", (await ReadAll(ranged)).SequenceEqual(body[5..10]), true);
Check("NoSuchKey", await CodeOf(() => s3.GetObjectAsync(b, "nope")), "NoSuchKey");

for (var i = 0; i < 23; i++) { await s3.PutObjectAsync(new PutObjectRequest { BucketName = b, Key = $"l/{i:D2}", ContentBody = "" }); }
var listed = 0;
await foreach (var o in s3.Paginators.ListObjectsV2(new ListObjectsV2Request { BucketName = b, Prefix = "l/", MaxKeys = 5 }).S3Objects)
{
    listed++;
}
Check("list paginator", listed, 23);

// Multipart with the TransferUtility, both ways.
var big = new byte[13 << 20];
new Random(2).NextBytes(big);
var transfer = new TransferUtility(s3, new TransferUtilityConfig { MinSizeBeforePartUpload = 5 << 20 });
await transfer.UploadAsync(new TransferUtilityUploadRequest
{
    BucketName = b, Key = "m/big", InputStream = new MemoryStream(big), PartSize = 5 << 20,
});
var head = await s3.GetObjectMetadataAsync(b, "m/big");
Check("multipart ETag", head.ETag.EndsWith("-3\""), true);
var downloaded = await ReadAll(await s3.GetObjectAsync(b, "m/big"));
Check("multipart download", downloaded.SequenceEqual(big), true);
await s3.CopyObjectAsync(b, "o/plain", b, "o/copy");
Check("copy", (await ReadAll(await s3.GetObjectAsync(b, "o/copy"))).SequenceEqual(body), true);

// Presigned URLs, through HttpClient.
var http = new HttpClient();
var getUrl = await s3.GetPreSignedURLAsync(new GetPreSignedUrlRequest
{
    BucketName = b, Key = "o/plain", Verb = HttpVerb.GET, Expires = DateTime.UtcNow.AddMinutes(1),
    Protocol = endpoint.StartsWith("https") ? Protocol.HTTPS : Protocol.HTTP,
});
Check("presigned GET", (await http.GetByteArrayAsync(getUrl)).SequenceEqual(body), true);
var putUrl = await s3.GetPreSignedURLAsync(new GetPreSignedUrlRequest
{
    BucketName = b, Key = "p/put", Verb = HttpVerb.PUT, Expires = DateTime.UtcNow.AddMinutes(1),
    Protocol = endpoint.StartsWith("https") ? Protocol.HTTPS : Protocol.HTTP,
});
var presignedPut = await http.PutAsync(putUrl, new ByteArrayContent(System.Text.Encoding.UTF8.GetBytes("presigned")));
Check("presigned PUT", (int)presignedPut.StatusCode, 200);

// Virtual-host addressing.
var v = Client(false);
await v.PutObjectAsync(new PutObjectRequest { BucketName = b, Key = "v/hosted", ContentBody = "virtual" });
Check("virtual-host", System.Text.Encoding.UTF8.GetString(await ReadAll(await v.GetObjectAsync(b, "v/hosted"))), "virtual");

// Tags, then everything goes.
await s3.PutObjectTaggingAsync(new PutObjectTaggingRequest
{
    BucketName = b, Key = "o/plain", Tagging = new Tagging { TagSet = [new Tag { Key = "k", Value = "v" }] },
});
Check("object tags", (await s3.GetObjectTaggingAsync(new GetObjectTaggingRequest { BucketName = b, Key = "o/plain" })).Tagging[0].Value, "v");
var keys = new List<KeyVersion>();
await foreach (var o in s3.Paginators.ListObjectsV2(new ListObjectsV2Request { BucketName = b }).S3Objects) { keys.Add(new KeyVersion { Key = o.Key }); }
var deleted = await s3.DeleteObjectsAsync(new DeleteObjectsRequest { BucketName = b, Objects = keys });
Check("delete objects", deleted.DeletedObjects.Count, keys.Count);
await s3.DeleteBucketAsync(b);
// A HEAD has no body: the .NET SDK reports its status, NotFound, where Java names NoSuchBucket.
Check("bucket deleted", await CodeOf(() => s3.GetObjectMetadataAsync(b, "x")), "NotFound");
return failed ? 1 : 0;
