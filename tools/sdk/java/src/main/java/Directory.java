// Directory buckets (ADR-0080) through the AWS SDK for Java v2: with the SDK's sessions (CreateSession) and with them
// off. ListDirectoryBuckets takes no session, and is listed with sessions off.
import java.net.URI;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.List;
import java.util.Random;
import software.amazon.awssdk.awscore.exception.AwsServiceException;
import software.amazon.awssdk.core.async.AsyncRequestBody;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3AsyncClient;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.*;

class Directory {
    static String codeOf(Runnable r) {
        try {
            r.run();
            return "no error";
        } catch (AwsServiceException e) {
            return e.awsErrorDetails().errorCode() == null ? String.valueOf(e.statusCode()) : e.awsErrorDetails().errorCode();
        }
    }

    static void run(URI endpoint) throws Exception {
        String dir = "sdk--local-az1--x-s3";
        S3Client lister = S3Client.builder().endpointOverride(endpoint).region(Region.US_EAST_1).forcePathStyle(true)
            .disableS3ExpressSessionAuth(true).build();
        for (boolean sessions : new boolean[] {true, false}) {
            String how = sessions ? " (sessions)" : " (sessions off)";
            S3Client d = S3Client.builder().endpointOverride(endpoint).region(Region.US_EAST_1).forcePathStyle(true)
                .disableS3ExpressSessionAuth(!sessions).build();
            CreateBucketResponse made = d.createBucket(r -> r.bucket(dir).createBucketConfiguration(c -> c
                .location(l -> l.type(LocationType.AVAILABILITY_ZONE).name("local-az1"))
                .bucket(b -> b.dataRedundancy(DataRedundancy.SINGLE_AVAILABILITY_ZONE).type(BucketType.DIRECTORY))));
            Check.check("create a directory bucket" + how, String.valueOf(made.bucketArn()).endsWith(":bucket/" + dir), true);
            Check.check("ListDirectoryBuckets" + how,
                lister.listDirectoryBuckets(r -> {}).buckets().stream().map(Bucket::name).toList(), List.of(dir));
            String body = "in a directory";
            PutObjectResponse put = d.putObject(r -> r.bucket(dir).key("a/b.txt"), RequestBody.fromString(body));
            String md5 = "\"" + HexFormat.of().formatHex(MessageDigest.getInstance("MD5").digest(body.getBytes())) + "\"";
            Check.check("an ETag that is not the MD5" + how, !put.eTag().equals(md5), true);
            Check.check("GET with If-Match" + how,
                d.getObjectAsBytes(r -> r.bucket(dir).key("a/b.txt").ifMatch(put.eTag())).asUtf8String(), body);
            Check.check("listed" + how, d.listObjectsV2(r -> r.bucket(dir).prefix("a/")).contents().stream().map(S3Object::key).toList(),
                List.of("a/b.txt"));
            byte[] big = new byte[12 << 20];
            new Random(3).nextBytes(big);
            try (S3AsyncClient async = S3AsyncClient.builder().endpointOverride(endpoint).region(Region.US_EAST_1)
                .forcePathStyle(true).disableS3ExpressSessionAuth(!sessions).multipartEnabled(true)
                .multipartConfiguration(m -> m.thresholdInBytes(5L << 20).minimumPartSizeInBytes(5L << 20)).build()) {
                async.putObject(r -> r.bucket(dir).key("big/m.bin"), AsyncRequestBody.fromBytes(big)).join();
            }
            Check.check("a multipart ETag without -N" + how, d.headObject(r -> r.bucket(dir).key("big/m.bin")).eTag().contains("-"), false);
            Check.check("no versioning" + how, codeOf(() -> d.putBucketVersioning(r -> r.bucket(dir)
                .versioningConfiguration(v -> v.status(BucketVersioningStatus.ENABLED)))), "NotImplemented");
            for (String k : List.of("a/b.txt", "big/m.bin")) d.deleteObject(r -> r.bucket(dir).key(k));
            d.deleteBucket(r -> r.bucket(dir));
            Check.check("deleted" + how, lister.listDirectoryBuckets(r -> {}).buckets().size(), 0);
        }
    }
}
