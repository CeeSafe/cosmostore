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
    catch (Amazon.Runtime.AmazonServiceException e) { return e.ErrorCode ?? ((int)e.StatusCode).ToString(); }
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

// M7 (ADR-0072 to ADR-0077): each item's configuration calls and what each does. common.sh starts serve with access
// logs every 2 s, a 3 s inventory day, websites under web.localhost and a role "reader" of sdk-m7.
async Task<bool> Until(Func<Task<bool>> f, int seconds = 15)
{
    var end = DateTime.UtcNow.AddSeconds(seconds);
    while (DateTime.UtcNow < end)
    {
        if (await f()) { return true; }
        await Task.Delay(250);
    }
    return false;
}
async Task<List<string>> KeysUnder(string bucket, string prefix) =>
    ((await s3.ListObjectsV2Async(new ListObjectsV2Request { BucketName = bucket, Prefix = prefix })).S3Objects ?? []).Select(o => o.Key).ToList();
async Task<string> Read(AmazonS3Client c, string bucket, string key)
{
    try { return System.Text.Encoding.UTF8.GetString(await ReadAll(await c.GetObjectAsync(bucket, key))); }
    catch (Amazon.Runtime.AmazonServiceException e) { return e.ErrorCode; }
}
async Task<string> Gone<T>(Func<Task<T>> get, Func<T, bool> empty, string code)
{
    // The .NET SDK gives some "not found" answers as an empty configuration rather than its error (the other SDKs
    // throw), so either is gone.
    try { return empty(await get()) ? "gone" : "still there"; }
    catch (Amazon.Runtime.AmazonServiceException e) { return e.ErrorCode == code ? "gone" : e.ErrorCode; }
}
const string m7 = "sdk-m7", logs = "sdk-m7-logs", account = "000000000000";
await s3.PutBucketAsync(m7);
await s3.PutBucketAsync(logs);
await s3.PutObjectAsync(new PutObjectRequest { BucketName = m7, Key = "index.html", ContentBody = "the index", ContentType = "text/html" });
await s3.PutObjectAsync(new PutObjectRequest { BucketName = m7, Key = "error.html", ContentBody = "the error page", ContentType = "text/html" });

// Access logs (ADR-0072).
await s3.PutBucketLoggingAsync(new PutBucketLoggingRequest
{
    BucketName = m7, LoggingConfig = new S3BucketLoggingConfig { TargetBucketName = logs, TargetPrefix = "access/" },
});
var lg = (await s3.GetBucketLoggingAsync(new GetBucketLoggingRequest { BucketName = m7 })).BucketLoggingConfig;
Check("GetBucketLogging", lg.TargetBucketName + " " + lg.TargetPrefix, logs + " access/");
Check("logging to a bucket that is not there", await CodeOf(() => s3.PutBucketLoggingAsync(new PutBucketLoggingRequest
{
    BucketName = m7, LoggingConfig = new S3BucketLoggingConfig { TargetBucketName = "sdk-nowhere", TargetPrefix = "x/" },
})), "InvalidTargetBucketForLogging");
await s3.PutObjectAsync(new PutObjectRequest { BucketName = m7, Key = "logged.txt", ContentBody = "logged" });
Check("the PUT's line in a log object", await Until(async () =>
{
    foreach (var k in await KeysUnder(logs, "access/"))
    {
        if ((await Read(s3, logs, k)).Contains("REST.PUT.OBJECT logged.txt")) { return true; }
    }
    return false;
}), true);
await s3.PutBucketLoggingAsync(new PutBucketLoggingRequest { BucketName = m7, LoggingConfig = new S3BucketLoggingConfig() });
var off = (await s3.GetBucketLoggingAsync(new GetBucketLoggingRequest { BucketName = m7 })).BucketLoggingConfig;
Check("logging off", string.IsNullOrEmpty(off?.TargetBucketName), true);

// Website hosting (ADR-0073), through <bucket>.web.localhost, with a policy that lets anyone read.
await s3.PutBucketWebsiteAsync(new PutBucketWebsiteRequest
{
    BucketName = m7, WebsiteConfiguration = new WebsiteConfiguration { IndexDocumentSuffix = "index.html", ErrorDocument = "error.html" },
});
var ws = (await s3.GetBucketWebsiteAsync(new GetBucketWebsiteRequest { BucketName = m7 })).WebsiteConfiguration;
Check("GetBucketWebsite", ws.IndexDocumentSuffix + " " + ws.ErrorDocument, "index.html error.html");
await s3.PutBucketPolicyAsync(new PutBucketPolicyRequest
{
    BucketName = m7,
    Policy = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::sdk-m7/*\"}]}",
});
var port = endpoint[(endpoint.LastIndexOf(':') + 1)..];
async Task<string> Page(string path)
{
    var req = new HttpRequestMessage(HttpMethod.Get, endpoint + path);
    req.Headers.Host = $"{m7}.web.localhost:{port}";
    var resp = await http.SendAsync(req);
    return (int)resp.StatusCode + " " + await resp.Content.ReadAsStringAsync();
}
Check("the site's index", await Page("/"), "200 the index");
Check("the site's error document", await Page("/no-such-page"), "404 the error page");
await s3.DeleteBucketWebsiteAsync(new DeleteBucketWebsiteRequest { BucketName = m7 });
Check("the website deleted", await Gone(() => s3.GetBucketWebsiteAsync(new GetBucketWebsiteRequest { BucketName = m7 }),
    r => string.IsNullOrEmpty(r.WebsiteConfiguration?.IndexDocumentSuffix), "NoSuchWebsiteConfiguration"), "gone");
await s3.DeleteBucketPolicyAsync(new DeleteBucketPolicyRequest { BucketName = m7 });

// Inventory (ADR-0074): a daily CSV report into the logs bucket; a day is 3 s here.
PutBucketInventoryConfigurationRequest Inventory(string id, string accountId) => new()
{
    BucketName = m7, InventoryId = id,
    InventoryConfiguration = new InventoryConfiguration
    {
        InventoryId = id, IsEnabled = true, IncludedObjectVersions = InventoryIncludedObjectVersions.Current,
        Schedule = new InventorySchedule { Frequency = InventoryFrequency.Daily },
        Destination = new InventoryDestination
        {
            S3BucketDestination = new InventoryS3BucketDestination
            {
                BucketName = "arn:aws:s3:::" + logs, InventoryFormat = InventoryFormat.CSV, Prefix = "inv", AccountId = accountId,
            },
        },
    },
};
await s3.PutBucketInventoryConfigurationAsync(Inventory("daily", null));
var inv = (await s3.GetBucketInventoryConfigurationAsync(new GetBucketInventoryConfigurationRequest { BucketName = m7, InventoryId = "daily" })).InventoryConfiguration;
Check("GetBucketInventoryConfiguration", $"{inv.InventoryId} {inv.IsEnabled} {inv.Schedule.Frequency} {inv.Destination.S3BucketDestination.BucketName}",
    "daily True Daily arn:aws:s3:::" + logs);
Check("ListBucketInventoryConfigurations", (await s3.ListBucketInventoryConfigurationsAsync(new ListBucketInventoryConfigurationsRequest { BucketName = m7 }))
    .InventoryConfigurationList.Count, 1);
Check("an account id is not done, not dropped", await CodeOf(() => s3.PutBucketInventoryConfigurationAsync(Inventory("acct", "111122223333"))), "NotImplemented");
string manifest = null;
await Until(async () => (manifest = (await KeysUnder(logs, "inv/")).FirstOrDefault(k => k.EndsWith("manifest.json"))) != null, 20);
Check("a report's manifest", manifest != null, true);
if (manifest != null)
{
    var files = System.Text.Json.JsonDocument.Parse(await Read(s3, logs, manifest)).RootElement.GetProperty("files");
    var gz = await ReadAll(await s3.GetObjectAsync(logs, files[0].GetProperty("key").GetString()));
    using var unzip = new StreamReader(new System.IO.Compression.GZipStream(new MemoryStream(gz), System.IO.Compression.CompressionMode.Decompress));
    var listedKeys = (await unzip.ReadToEndAsync()).Trim().Split('\n').Select(l => l.Split(',')[1].Trim('"')).Order();
    Check("its CSV has every object", string.Join(" ", listedKeys), "error.html index.html logged.txt");
}
await s3.DeleteBucketInventoryConfigurationAsync(new DeleteBucketInventoryConfigurationRequest { BucketName = m7, InventoryId = "daily" });
Check("the inventory deleted", await Gone(() => s3.GetBucketInventoryConfigurationAsync(new GetBucketInventoryConfigurationRequest
{
    BucketName = m7, InventoryId = "daily",
}), r => r.InventoryConfiguration?.InventoryId == null, "NoSuchConfiguration"), "gone");

// STS (ADR-0075): a session token, and the role "reader", sign S3 requests.
var sts = new Amazon.SecurityToken.AmazonSecurityTokenServiceClient(new Amazon.SecurityToken.AmazonSecurityTokenServiceConfig
{
    ServiceURL = endpoint, AuthenticationRegion = "us-east-1", MaxErrorRetry = 0,
});
AmazonS3Client As(Amazon.SecurityToken.Model.Credentials c) => new(
    new Amazon.Runtime.SessionAWSCredentials(c.AccessKeyId, c.SecretAccessKey, c.SessionToken),
    new AmazonS3Config { ServiceURL = endpoint, ForcePathStyle = true, AuthenticationRegion = "us-east-1", MaxErrorRetry = 0 });
var session = (await sts.GetSessionTokenAsync(new Amazon.SecurityToken.Model.GetSessionTokenRequest { DurationSeconds = 900 })).Credentials;
Check("GetSessionToken gives an ASIA key", session.AccessKeyId[..4], "ASIA");
Check("the session reads", await Read(As(session), m7, "logged.txt"), "logged");
var reader = As((await sts.AssumeRoleAsync(new Amazon.SecurityToken.Model.AssumeRoleRequest
{
    RoleArn = $"arn:aws:iam::{account}:role/reader", RoleSessionName = "dotnet",
})).Credentials);
Check("the role reads", await Read(reader, m7, "logged.txt"), "logged");
Check("the role does not write", await CodeOf(() => reader.PutObjectAsync(new PutObjectRequest { BucketName = m7, Key = "no", ContentBody = "no" })), "AccessDenied");
Check("nor read another bucket", await CodeOf(() => reader.ListObjectsV2Async(new ListObjectsV2Request { BucketName = logs })), "AccessDenied");
Check("policy ARNs are not done, not dropped", await CodeOf(() => sts.AssumeRoleAsync(new Amazon.SecurityToken.Model.AssumeRoleRequest
{
    RoleArn = $"arn:aws:iam::{account}:role/reader", RoleSessionName = "arns",
    PolicyArns = [new Amazon.SecurityToken.Model.PolicyDescriptorType { Arn = "arn:aws:iam::aws:policy/ReadOnlyAccess" }],
})), "NotImplemented");

// Access Points (ADR-0076): S3 Control puts the account in the host (`<account>.localhost`); a request by ARN goes
// to `<name>-<account>.localhost`.
var ctl = new Amazon.S3Control.AmazonS3ControlClient(new Amazon.S3Control.AmazonS3ControlConfig
{
    ServiceURL = endpoint.Replace("127.0.0.1", "localhost"), AuthenticationRegion = "us-east-1", MaxErrorRetry = 0,
});
var made = await ctl.CreateAccessPointAsync(new Amazon.S3Control.Model.CreateAccessPointRequest { AccountId = account, Name = "sdk-ap", Bucket = m7 });
Check("CreateAccessPoint gives an alias", (made.Alias ?? "").EndsWith("-s3alias"), true);
var ap = await ctl.GetAccessPointAsync(new Amazon.S3Control.Model.GetAccessPointRequest { AccountId = account, Name = "sdk-ap" });
Check("GetAccessPoint", ap.Bucket + " " + ap.NetworkOrigin, m7 + " Internet");
Check("ListAccessPoints", (await ctl.ListAccessPointsAsync(new Amazon.S3Control.Model.ListAccessPointsRequest { AccountId = account, Bucket = m7 }))
    .AccessPointList.Count, 1);
Check("a name twice", await CodeOf(() => ctl.CreateAccessPointAsync(new Amazon.S3Control.Model.CreateAccessPointRequest
{
    AccountId = account, Name = "sdk-ap", Bucket = m7,
})), "AccessPointAlreadyOwnedByYou");
await s3.PutObjectAsync(new PutObjectRequest { BucketName = made.Alias, Key = "ap/door.txt", ContentBody = "through a door" });
Check("a write by its alias lands in its bucket", await Read(s3, m7, "ap/door.txt"), "through a door");
Check("a read by its ARN", await Read(Client(false), $"arn:aws:s3:us-east-1:{account}:accesspoint/sdk-ap", "ap/door.txt"), "through a door");
await ctl.DeleteAccessPointAsync(new Amazon.S3Control.Model.DeleteAccessPointRequest { AccountId = account, Name = "sdk-ap" });
Check("the access point deleted", await CodeOf(() => ctl.GetAccessPointAsync(new Amazon.S3Control.Model.GetAccessPointRequest
{
    AccountId = account, Name = "sdk-ap",
})), "NoSuchAccessPoint");

// Replication (ADR-0077): a new version copied to another bucket with its version id and ETag.
const string rs = "sdk-rsrc", rd = "sdk-rdst";
foreach (var bucket in new[] { rs, rd })
{
    await s3.PutBucketAsync(bucket);
    await s3.PutBucketVersioningAsync(new PutBucketVersioningRequest
    {
        BucketName = bucket, VersioningConfig = new S3BucketVersioningConfig { Status = VersionStatus.Enabled },
    });
}
ReplicationRule Rule(string id) => new()
{
    Id = id, Priority = 1, Status = ReplicationRuleStatus.Enabled,
    Filter = new ReplicationRuleFilter { Prefix = "" },
    DeleteMarkerReplication = new DeleteMarkerReplication { Status = DeleteMarkerReplicationStatus.Enabled },
    Destination = new ReplicationDestination { BucketArn = "arn:aws:s3:::" + rd },
};
PutBucketReplicationRequest Replication(params ReplicationRule[] rules) => new()
{
    BucketName = rs, Configuration = new ReplicationConfiguration { Role = $"arn:aws:iam::{account}:role/r", Rules = rules.ToList() },
};
Check("one priority twice", await CodeOf(() => s3.PutBucketReplicationAsync(Replication(Rule("all"), Rule("again")))), "InvalidArgument");
await s3.PutBucketReplicationAsync(Replication(Rule("all")));
Check("GetBucketReplication", (await s3.GetBucketReplicationAsync(new GetBucketReplicationRequest { BucketName = rs }))
    .Configuration.Rules[0].Destination.BucketArn, "arn:aws:s3:::" + rd);
var src = await s3.PutObjectAsync(new PutObjectRequest { BucketName = rs, Key = "r/one.txt", ContentBody = "replicate me" });
Check("replicated", await Until(async () => (await s3.GetObjectMetadataAsync(rs, "r/one.txt")).ReplicationStatus == ReplicationStatus.Completed), true);
var replica = await s3.GetObjectMetadataAsync(rd, "r/one.txt");
Check("the replica keeps its version id and ETag", replica.VersionId + " " + replica.ETag, src.VersionId + " " + src.ETag);
Check("and is a replica", replica.ReplicationStatus?.Value, "REPLICA");
await s3.DeleteBucketReplicationAsync(new DeleteBucketReplicationRequest { BucketName = rs });
Check("the replication deleted", await Gone(() => s3.GetBucketReplicationAsync(new GetBucketReplicationRequest { BucketName = rs }),
    r => (r.Configuration?.Rules?.Count ?? 0) == 0, "ReplicationConfigurationNotFoundError"), "gone");

// Directory buckets (ADR-0080), with the SDK's sessions off: with them on, its S3 Express pre-signer takes the request's
// URI apart as an AWS S3 host name and fails before sending ("Invalid S3 URI") against any other endpoint.
AmazonS3Client DirClient(bool sessions) => new(new AmazonS3Config
{
    ServiceURL = endpoint, ForcePathStyle = true, AuthenticationRegion = "us-east-1", MaxErrorRetry = 0,
    DisableS3ExpressSessionAuth = !sessions,
});
const string dirBucket = "sdk--local-az1--x-s3";
var dirLister = DirClient(false);
foreach (var sessions in new[] { false })
{
    var how = sessions ? " (sessions)" : " (sessions off)";
    var d = DirClient(sessions);
    var dirMade = await d.PutBucketAsync(new PutBucketRequest
    {
        BucketName = dirBucket,
        PutBucketConfiguration = new PutBucketConfiguration
        {
            Location = new LocationInfo { Type = LocationType.AvailabilityZone, Name = "local-az1" },
            BucketInfo = new BucketInfo { DataRedundancy = DataRedundancy.SingleAvailabilityZone, Type = BucketType.Directory },
        },
    });
    Check("create a directory bucket" + how, (int)dirMade.HttpStatusCode, 200);
    Check("ListDirectoryBuckets" + how, string.Join(",", (await dirLister.ListDirectoryBucketsAsync(new ListDirectoryBucketsRequest())).Buckets.Select(x => x.BucketName)), dirBucket);
    var dirPut = await d.PutObjectAsync(new PutObjectRequest { BucketName = dirBucket, Key = "a/b.txt", ContentBody = "in a directory" });
    Check("an ETag that is not the MD5" + how, dirPut.ETag != Md5(System.Text.Encoding.UTF8.GetBytes("in a directory")), true);
    Check("GET with If-Match" + how, System.Text.Encoding.UTF8.GetString(await ReadAll(await d.GetObjectAsync(new GetObjectRequest
    {
        BucketName = dirBucket, Key = "a/b.txt", EtagToMatch = dirPut.ETag,
    }))), "in a directory");
    Check("listed" + how, string.Join(",", (await d.ListObjectsV2Async(new ListObjectsV2Request { BucketName = dirBucket, Prefix = "a/" })).S3Objects.Select(o => o.Key)), "a/b.txt");
    var dirBig = new byte[12 << 20];
    new Random(4).NextBytes(dirBig);
    await new TransferUtility(d, new TransferUtilityConfig { MinSizeBeforePartUpload = 5 << 20 }).UploadAsync(new TransferUtilityUploadRequest
    {
        BucketName = dirBucket, Key = "big/m.bin", InputStream = new MemoryStream(dirBig), PartSize = 5 << 20,
    });
    Check("a multipart ETag without -N" + how, (await d.GetObjectMetadataAsync(dirBucket, "big/m.bin")).ETag.Contains('-'), false);
    Check("no versioning" + how, await CodeOf(() => d.PutBucketVersioningAsync(new PutBucketVersioningRequest
    {
        BucketName = dirBucket, VersioningConfig = new S3BucketVersioningConfig { Status = VersionStatus.Enabled },
    })), "NotImplemented");
    foreach (var k in new[] { "a/b.txt", "big/m.bin" }) { await d.DeleteObjectAsync(dirBucket, k); }
    await d.DeleteBucketAsync(dirBucket);
    Check("deleted" + how, (await dirLister.ListDirectoryBucketsAsync(new ListDirectoryBucketsRequest())).Buckets?.Count ?? 0, 0);
}

// A directory bucket's access point (ADR-0082): made with a scope; requests through it with sessions off.
{
    const string apBucket = "sdk4--local-az1--x-s3", door = "sdknet--local-az1--xa-s3";
    var d = DirClient(false);
    await d.PutBucketAsync(new PutBucketRequest
    {
        BucketName = apBucket,
        PutBucketConfiguration = new PutBucketConfiguration
        {
            Location = new LocationInfo { Type = LocationType.AvailabilityZone, Name = "local-az1" },
            BucketInfo = new BucketInfo { DataRedundancy = DataRedundancy.SingleAvailabilityZone, Type = BucketType.Directory },
        },
    });
    var dirAp = await ctl.CreateAccessPointAsync(new Amazon.S3Control.Model.CreateAccessPointRequest
    {
        AccountId = account, Name = door, Bucket = apBucket,
        Scope = new Amazon.S3Control.Model.Scope { Prefixes = new List<string> { "pub/" }, Permissions = new List<string> { "GetObject", "PutObject" } },
    });
    Check("directory access point: its alias is its name", dirAp.Alias, door);
    var scope = (await ctl.GetAccessPointScopeAsync(new Amazon.S3Control.Model.GetAccessPointScopeRequest { AccountId = account, Name = door })).Scope;
    Check("GetAccessPointScope", string.Join(",", scope.Prefixes) + " " + string.Join(",", scope.Permissions), "pub/ GetObject,PutObject");
    Check("ListAccessPointsForDirectoryBuckets", string.Join(",", (await ctl.ListAccessPointsForDirectoryBucketsAsync(
        new Amazon.S3Control.Model.ListAccessPointsForDirectoryBucketsRequest { AccountId = account, DirectoryBucket = apBucket })).AccessPointList.Select(a => a.Name)), door);
    await d.PutObjectAsync(new PutObjectRequest { BucketName = door, Key = "pub/a.txt", ContentBody = "through" });
    Check("a GET through it", System.Text.Encoding.UTF8.GetString(await ReadAll(await d.GetObjectAsync(new GetObjectRequest { BucketName = door, Key = "pub/a.txt" }))), "through");
    Check("a key outside its scope", await CodeOf(() => d.GetObjectAsync(new GetObjectRequest { BucketName = door, Key = "other/a.txt" })), "AccessDenied");
    Check("a permission outside its scope", await CodeOf(() => d.DeleteObjectAsync(door, "pub/a.txt")), "AccessDenied");
    await ctl.DeleteAccessPointAsync(new Amazon.S3Control.Model.DeleteAccessPointRequest { AccountId = account, Name = door });
    await d.DeleteObjectAsync(apBucket, "pub/a.txt");
    await d.DeleteBucketAsync(apBucket);
}
// The long tail (ADR-0090): storage classes recorded, or refused.
{
    var tail = Client(true);
    await tail.PutBucketAsync(new PutBucketRequest { BucketName = "sdk-net-tail" });
    await tail.PutObjectAsync(new PutObjectRequest { BucketName = "sdk-net-tail", Key = "ia", ContentBody = "x", StorageClass = S3StorageClass.StandardInfrequentAccess });
    var tailHead = await tail.GetObjectMetadataAsync("sdk-net-tail", "ia");
    Check("a storage class recorded", tailHead.StorageClass?.Value, "STANDARD_IA");
    Check("an archive class refused", await CodeOf(() => tail.PutObjectAsync(new PutObjectRequest { BucketName = "sdk-net-tail", Key = "g", ContentBody = "x", StorageClass = S3StorageClass.Glacier })), "InvalidStorageClass");
    await tail.DeleteObjectAsync("sdk-net-tail", "ia");
    await tail.DeleteBucketAsync("sdk-net-tail");
}

// Users (ADR-0088): a user's key reads what its identity policy allows, and nothing else.
{
    var owner = Client(true);
    await owner.PutBucketAsync(new PutBucketRequest { BucketName = "sdk-net-users" });
    await owner.PutObjectAsync(new PutObjectRequest { BucketName = "sdk-net-users", Key = "a", ContentBody = "read me" });
    var user = new AmazonS3Client(new Amazon.Runtime.BasicAWSCredentials("AKIASDKUSER000000001", "sdkuser/secret/0123456789abcdefgh"),
        new AmazonS3Config { ServiceURL = endpoint, ForcePathStyle = true, AuthenticationRegion = "us-east-1", MaxErrorRetry = 0 });
    using (var userGot = await user.GetObjectAsync("sdk-net-users", "a"))
    using (var userReader = new StreamReader(userGot.ResponseStream))
    {
        Check("a user reads", await userReader.ReadToEndAsync(), "read me");
    }
    Check("a user writes nothing", await CodeOf(() => user.PutObjectAsync(new PutObjectRequest { BucketName = "sdk-net-users", Key = "b", ContentBody = "x" })), "AccessDenied");
    Check("nor lists every bucket", await CodeOf(() => user.ListBucketsAsync()), "AccessDenied");
    await owner.DeleteObjectAsync("sdk-net-users", "a");
    await owner.DeleteBucketAsync("sdk-net-users");
}

// S3 Tables (ADR-0083): table buckets, namespaces and tables, and the metadata location's compare-and-set.
{
    var t = new Amazon.S3Tables.AmazonS3TablesClient(new Amazon.S3Tables.AmazonS3TablesConfig
    {
        ServiceURL = endpoint, AuthenticationRegion = "us-east-1", MaxErrorRetry = 0,
    });
    var arn = (await t.CreateTableBucketAsync(new Amazon.S3Tables.Model.CreateTableBucketRequest { Name = "sdk-net-tables" })).Arn;
    Check("CreateTableBucket", arn, $"arn:aws:s3tables:us-east-1:{account}:bucket/sdk-net-tables");
    Check("ListTableBuckets", string.Join(",", (await t.ListTableBucketsAsync(new Amazon.S3Tables.Model.ListTableBucketsRequest())).TableBuckets.Select(b => b.Name)), "sdk-net-tables");
    await t.CreateNamespaceAsync(new Amazon.S3Tables.Model.CreateNamespaceRequest { TableBucketARN = arn, Namespace = new List<string> { "sales" } });
    var tableMade = await t.CreateTableAsync(new Amazon.S3Tables.Model.CreateTableRequest
    {
        TableBucketARN = arn, Namespace = "sales", Name = "orders", Format = Amazon.S3Tables.OpenTableFormat.ICEBERG,
    });
    var tableGot = await t.GetTableAsync(new Amazon.S3Tables.Model.GetTableRequest { TableArn = tableMade.TableARN });
    Check("GetTable by its ARN", tableGot.Name, "orders");
    var wh = tableGot.WarehouseLocation;
    var parts = wh.Substring(5).Split('/', 2);
    await s3.PutObjectAsync(new PutObjectRequest { BucketName = parts[0], Key = parts[1] + "/metadata/00001-n.metadata.json", ContentBody = "{}" });
    var moved = await t.UpdateTableMetadataLocationAsync(new Amazon.S3Tables.Model.UpdateTableMetadataLocationRequest
    {
        TableBucketARN = arn, Namespace = "sales", Name = "orders", VersionToken = tableGot.VersionToken,
        MetadataLocation = wh + "/metadata/00001-n.metadata.json",
    });
    Check("UpdateTableMetadataLocation", moved.MetadataLocation, wh + "/metadata/00001-n.metadata.json");
    Check("a stale versionToken", await CodeOf(() => t.UpdateTableMetadataLocationAsync(new Amazon.S3Tables.Model.UpdateTableMetadataLocationRequest
    {
        TableBucketARN = arn, Namespace = "sales", Name = "orders", VersionToken = tableGot.VersionToken,
        MetadataLocation = wh + "/metadata/00002-n.metadata.json",
    })), "ConflictException");
    await t.RenameTableAsync(new Amazon.S3Tables.Model.RenameTableRequest { TableBucketARN = arn, Namespace = "sales", Name = "orders", NewName = "orders2" });
    Check("RenameTable", string.Join(",", (await t.ListTablesAsync(new Amazon.S3Tables.Model.ListTablesRequest { TableBucketARN = arn })).Tables.Select(x => x.Name)), "orders2");
    // Maintenance (ADR-0086): a table bucket's configuration put and read back; compaction is not done.
    await t.PutTableBucketMaintenanceConfigurationAsync(new Amazon.S3Tables.Model.PutTableBucketMaintenanceConfigurationRequest
    {
        TableBucketARN = arn, Type = Amazon.S3Tables.TableBucketMaintenanceType.IcebergUnreferencedFileRemoval,
        Value = new Amazon.S3Tables.Model.TableBucketMaintenanceConfigurationValue
        {
            Status = Amazon.S3Tables.MaintenanceStatus.Enabled,
            Settings = new Amazon.S3Tables.Model.TableBucketMaintenanceSettings
            {
                IcebergUnreferencedFileRemoval = new Amazon.S3Tables.Model.IcebergUnreferencedFileRemovalSettings { UnreferencedDays = 4, NonCurrentDays = 9 },
            },
        },
    });
    var bm = await t.GetTableBucketMaintenanceConfigurationAsync(new Amazon.S3Tables.Model.GetTableBucketMaintenanceConfigurationRequest { TableBucketARN = arn });
    Check("GetTableBucketMaintenanceConfiguration", bm.Configuration["icebergUnreferencedFileRemoval"].Settings.IcebergUnreferencedFileRemoval.UnreferencedDays ?? 0, 4);
    var tm = await t.GetTableMaintenanceConfigurationAsync(new Amazon.S3Tables.Model.GetTableMaintenanceConfigurationRequest { TableBucketARN = arn, Namespace = "sales", Name = "orders2" });
    Check("GetTableMaintenanceConfiguration: compaction off", tm.Configuration["icebergCompaction"].Status.Value, "disabled");
    var jobs = await t.GetTableMaintenanceJobStatusAsync(new Amazon.S3Tables.Model.GetTableMaintenanceJobStatusRequest { TableBucketARN = arn, Namespace = "sales", Name = "orders2" });
    Check("GetTableMaintenanceJobStatus", jobs.Status["icebergCompaction"].Status.Value, "Disabled");
    await t.DeleteTableAsync(new Amazon.S3Tables.Model.DeleteTableRequest { TableBucketARN = arn, Namespace = "sales", Name = "orders2" });
    await t.DeleteNamespaceAsync(new Amazon.S3Tables.Model.DeleteNamespaceRequest { TableBucketARN = arn, Namespace = "sales" });
    await t.DeleteTableBucketAsync(new Amazon.S3Tables.Model.DeleteTableBucketRequest { TableBucketARN = arn });
    Check("DeleteTableBucket", (await t.ListTableBucketsAsync(new Amazon.S3Tables.Model.ListTableBucketsRequest())).TableBuckets?.Count ?? 0, 0);
}
return failed ? 1 : 0;
