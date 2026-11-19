// Users (ADR-0088) through the AWS SDK for Java v2: a user's key reads what its identity policy allows, and nothing
// else.
import java.net.URI;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;

class Users {
    static void run(URI endpoint) {
        S3Client account = S3Client.builder().endpointOverride(endpoint).region(Region.US_EAST_1).forcePathStyle(true).build();
        account.createBucket(r -> r.bucket("sdk-java-users"));
        account.putObject(r -> r.bucket("sdk-java-users").key("a"), RequestBody.fromString("read me"));
        S3Client user = S3Client.builder().endpointOverride(endpoint).region(Region.US_EAST_1).forcePathStyle(true)
            .credentialsProvider(StaticCredentialsProvider.create(
                AwsBasicCredentials.create("AKIASDKUSER000000001", "sdkuser/secret/0123456789abcdefgh")))
            .build();
        Check.check("a user reads", user.getObjectAsBytes(r -> r.bucket("sdk-java-users").key("a")).asUtf8String(), "read me");
        Check.check("a user writes nothing", Directory.codeOf(() -> user.putObject(r -> r.bucket("sdk-java-users").key("b"),
            RequestBody.fromString("x"))), "AccessDenied");
        Check.check("nor lists every bucket", Directory.codeOf(() -> user.listBuckets()), "AccessDenied");
        account.deleteObject(r -> r.bucket("sdk-java-users").key("a"));
        account.deleteBucket(r -> r.bucket("sdk-java-users"));
    }
}
