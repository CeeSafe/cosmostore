// The AWS SDK for Java v2 against `cosmostore serve` (M3 SDK matrix). Run by tools/sdk/java.sh, which starts the
// server and sets AWS_ENDPOINT_URL and the credentials. Prints one line per check; exit status 1 if any fails.
import java.io.ByteArrayInputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.security.MessageDigest;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Random;
import software.amazon.awssdk.core.ResponseBytes;
import software.amazon.awssdk.core.async.AsyncRequestBody;
import software.amazon.awssdk.core.async.AsyncResponseTransformer;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3AsyncClient;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.*;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;

public class Check {
    static boolean failed = false;

    static void check(String name, Object got, Object want) {
        if (Objects.equals(got, want)) {
            System.out.println("ok   " + name);
        } else {
            System.out.println("FAIL " + name + ": expected [" + want + "], got [" + got + "]");
            failed = true;
        }
    }

    static String codeOf(Runnable r) {
        try {
            r.run();
            return "no error";
        } catch (S3Exception e) {
            return e.awsErrorDetails().errorCode() == null ? String.valueOf(e.statusCode()) : e.awsErrorDetails().errorCode();
        }
    }

    static String md5(byte[] data) throws Exception {
        return "\"" + HexFormat.of().formatHex(MessageDigest.getInstance("MD5").digest(data)) + "\"";
    }

    public static void main(String[] args) throws Exception {
        URI endpoint = URI.create(System.getenv("AWS_ENDPOINT_URL"));
        S3Client s3 = S3Client.builder().endpointOverride(endpoint).region(Region.US_EAST_1).forcePathStyle(true).build();
        String b = "java-sdk-test";
        s3.createBucket(r -> r.bucket(b));
        check("create twice", codeOf(() -> s3.createBucket(r -> r.bucket(b))), "BucketAlreadyOwnedByYou");

        byte[] body = new byte[300000];
        new Random(1).nextBytes(body);
        PutObjectResponse put = s3.putObject(r -> r.bucket(b).key("o/plain").contentType("x/y").metadata(Map.of("k", "v")),
                RequestBody.fromBytes(body));
        check("put ETag", put.eTag(), md5(body));
        for (ChecksumAlgorithm algo : List.of(ChecksumAlgorithm.CRC32, ChecksumAlgorithm.CRC32_C, ChecksumAlgorithm.SHA256,
                ChecksumAlgorithm.CRC64_NVME)) {
            String key = "o/" + algo;
            s3.putObject(r -> r.bucket(b).key(key).checksumAlgorithm(algo), RequestBody.fromBytes(body));
            check("put with " + algo, Arrays.equals(s3.getObjectAsBytes(r -> r.bucket(b).key(key)).asByteArray(), body), true);
        }
        ResponseBytes<GetObjectResponse> got = s3.getObjectAsBytes(r -> r.bucket(b).key("o/plain"));
        check("get", Arrays.equals(got.asByteArray(), body), true);
        check("content type and metadata", got.response().contentType() + " " + got.response().metadata(), "x/y {k=v}");
        // The SDK sends a CRC32 with each PUT by default, so that is what the object keeps, and what GET validates.
        GetObjectResponse checked = s3.getObjectAsBytes(r -> r.bucket(b).key("o/plain").checksumMode(ChecksumMode.ENABLED))
                .response();
        check("checksum returned on GET", checked.checksumCRC32() != null || checked.checksumCRC64NVME() != null, true);
        check("range", Arrays.equals(s3.getObjectAsBytes(r -> r.bucket(b).key("o/plain").range("bytes=5-9")).asByteArray(),
                Arrays.copyOfRange(body, 5, 10)), true);
        try {
            s3.getObject(r -> r.bucket(b).key("nope"));
            check("NoSuchKeyException", "no error", "NoSuchKeyException");
        } catch (NoSuchKeyException e) {
            check("NoSuchKeyException", "NoSuchKeyException", "NoSuchKeyException");
        }
        // A HEAD has no body, so the SDK names the error from the status.
        check("head missing", codeOf(() -> s3.headObject(r -> r.bucket(b).key("nope"))), "NoSuchKey");

        for (int i = 0; i < 23; i++) {
            String key = String.format("l/%02d", i);
            s3.putObject(r -> r.bucket(b).key(key), RequestBody.empty());
        }
        long n = s3.listObjectsV2Paginator(r -> r.bucket(b).prefix("l/").maxKeys(5)).contents().stream().count();
        check("list paginator", n, 23L);

        // Multipart through the SDK's own async multipart client, and its parallel download.
        byte[] big = new byte[13 << 20];
        new Random(2).nextBytes(big);
        try (S3AsyncClient async = S3AsyncClient.builder().endpointOverride(endpoint).region(Region.US_EAST_1)
                .forcePathStyle(true).multipartEnabled(true)
                .multipartConfiguration(c -> c.minimumPartSizeInBytes(5L << 20).thresholdInBytes(5L << 20)).build()) {
            async.putObject(r -> r.bucket(b).key("m/big"), AsyncRequestBody.fromBytes(big)).join();
            HeadObjectResponse head = s3.headObject(r -> r.bucket(b).key("m/big"));
            check("multipart ETag", head.eTag().endsWith("-3\""), true);
            byte[] down = async.getObject(r -> r.bucket(b).key("m/big"), AsyncResponseTransformer.toBytes()).join().asByteArray();
            check("async get of the multipart object", Arrays.equals(down, big), true);
            async.copyObject(r -> r.sourceBucket(b).sourceKey("m/big").destinationBucket(b).destinationKey("m/copy")).join();
            check("multipart copy", Arrays.equals(s3.getObjectAsBytes(r -> r.bucket(b).key("m/copy")).asByteArray(), big), true);
        }
        s3.copyObject(r -> r.sourceBucket(b).sourceKey("o/plain").destinationBucket(b).destinationKey("o/copy"));
        check("copy", Arrays.equals(s3.getObjectAsBytes(r -> r.bucket(b).key("o/copy")).asByteArray(), body), true);

        // Presigned URLs, through the JDK's own HTTP client.
        HttpClient http = HttpClient.newHttpClient();
        try (S3Presigner presigner = S3Presigner.builder().endpointOverride(endpoint).region(Region.US_EAST_1)
                .serviceConfiguration(software.amazon.awssdk.services.s3.S3Configuration.builder().pathStyleAccessEnabled(true).build())
                .build()) {
            String getUrl = presigner.presignGetObject(r -> r.signatureDuration(Duration.ofMinutes(1))
                    .getObjectRequest(g -> g.bucket(b).key("o/plain"))).url().toString();
            HttpResponse<byte[]> g = http.send(HttpRequest.newBuilder(URI.create(getUrl)).build(), HttpResponse.BodyHandlers.ofByteArray());
            check("presigned GET", Arrays.equals(g.body(), body), true);
            String putUrl = presigner.presignPutObject(r -> r.signatureDuration(Duration.ofMinutes(1))
                    .putObjectRequest(p -> p.bucket(b).key("p/put"))).url().toString();
            HttpResponse<String> p = http.send(HttpRequest.newBuilder(URI.create(putUrl))
                    .PUT(HttpRequest.BodyPublishers.ofString("presigned")).build(), HttpResponse.BodyHandlers.ofString());
            check("presigned PUT", p.statusCode(), 200);
        }

        // Virtual-host addressing.
        S3Client v = S3Client.builder().endpointOverride(URI.create(endpoint.toString().replace("127.0.0.1", "localhost")))
                .region(Region.US_EAST_1).forcePathStyle(false).build();
        v.putObject(r -> r.bucket(b).key("v/hosted"), RequestBody.fromString("virtual"));
        check("virtual-host", v.getObjectAsBytes(r -> r.bucket(b).key("v/hosted")).asUtf8String(), "virtual");

        // Tags, then everything goes.
        s3.putObjectTagging(r -> r.bucket(b).key("o/plain").tagging(t -> t.tagSet(Tag.builder().key("k").value("v").build())));
        check("object tags", s3.getObjectTagging(r -> r.bucket(b).key("o/plain")).tagSet().get(0).value(), "v");
        List<ObjectIdentifier> ids = new ArrayList<>();
        s3.listObjectsV2Paginator(r -> r.bucket(b)).contents().forEach(o -> ids.add(ObjectIdentifier.builder().key(o.key()).build()));
        DeleteObjectsResponse del = s3.deleteObjects(r -> r.bucket(b).delete(d -> d.objects(ids)));
        check("delete objects", del.deleted().size(), ids.size());
        s3.deleteBucket(r -> r.bucket(b));
        check("bucket deleted", codeOf(() -> s3.headBucket(r -> r.bucket(b))), "NoSuchBucket");
        System.exit(failed ? 1 : 0);
    }
}
