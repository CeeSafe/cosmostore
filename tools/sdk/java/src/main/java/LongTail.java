// The long tail (ADR-0090) through the AWS SDK for Java v2: storage classes recorded, or refused.
import java.net.URI;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.StorageClass;

class LongTail {
    static void run(URI endpoint) {
        S3Client s3 = S3Client.builder().endpointOverride(endpoint).region(Region.US_EAST_1).forcePathStyle(true).build();
        s3.createBucket(r -> r.bucket("sdk-java-tail"));
        s3.putObject(r -> r.bucket("sdk-java-tail").key("ia").storageClass(StorageClass.STANDARD_IA), RequestBody.fromString("x"));
        Check.check("a storage class recorded", s3.headObject(r -> r.bucket("sdk-java-tail").key("ia")).storageClassAsString(), "STANDARD_IA");
        // An archive class (ADR-0102): taken; its read InvalidObjectState until restored.
        s3.putObject(r -> r.bucket("sdk-java-tail").key("g").storageClass(StorageClass.GLACIER), RequestBody.fromString("x"));
        Check.check("an archive class taken", s3.headObject(r -> r.bucket("sdk-java-tail").key("g")).storageClassAsString(), "GLACIER");
        Check.check("its read refused, not restored", Directory.codeOf(() -> s3.getObjectAsBytes(r -> r.bucket("sdk-java-tail").key("g"))), "InvalidObjectState");
        // RestoreObject (an hour is a second here: Standard's 4 hours take 4 s).
        s3.restoreObject(r -> r.bucket("sdk-java-tail").key("g").restoreRequest(q -> q.days(1).glacierJobParameters(g -> g.tier("Standard"))));
        Check.check("restoring", s3.headObject(r -> r.bucket("sdk-java-tail").key("g")).restore(), "ongoing-request=\"true\"");
        try { Thread.sleep(5000); } catch (InterruptedException e) { throw new RuntimeException(e); }
        Check.check("restored, read", s3.getObjectAsBytes(r -> r.bucket("sdk-java-tail").key("g")).asUtf8String(), "x");
        s3.deleteObject(r -> r.bucket("sdk-java-tail").key("g"));
        s3.deleteObject(r -> r.bucket("sdk-java-tail").key("ia"));
        s3.deleteBucket(r -> r.bucket("sdk-java-tail"));
    }
}
