// Access points of directory buckets (ADR-0082) through the AWS SDK for Java v2: made with a scope, requests through
// them with the SDK's sessions, and their own listing.
import java.net.URI;
import java.util.List;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.*;
import software.amazon.awssdk.services.s3control.S3ControlClient;
import software.amazon.awssdk.services.s3control.model.ScopePermission;

class DirectoryAccessPoints {
    static void run(URI endpoint) {
        String bucket = "sdk4--local-az1--x-s3", door = "sdkjava--local-az1--xa-s3", account = "000000000000";
        S3Client d = S3Client.builder().endpointOverride(endpoint).region(Region.US_EAST_1).forcePathStyle(true).build();
        d.createBucket(r -> r.bucket(bucket).createBucketConfiguration(c -> c
            .location(l -> l.type(LocationType.AVAILABILITY_ZONE).name("local-az1"))
            .bucket(b -> b.dataRedundancy(DataRedundancy.SINGLE_AVAILABILITY_ZONE).type(BucketType.DIRECTORY))));
        URI local = URI.create(endpoint.toString().replace("127.0.0.1", "localhost"));
        S3ControlClient ctl = S3ControlClient.builder().endpointOverride(local).region(Region.US_EAST_1).build();
        String alias = ctl.createAccessPoint(r -> r.accountId(account).name(door).bucket(bucket)
            .scope(s -> s.prefixes("pub/").permissions(ScopePermission.GET_OBJECT, ScopePermission.PUT_OBJECT))).alias();
        Check.check("directory access point: its alias is its name", alias, door);
        var scope = ctl.getAccessPointScope(r -> r.accountId(account).name(door)).scope();
        Check.check("GetAccessPointScope", scope.prefixes() + " " + scope.permissionsAsStrings(), "[pub/] [GetObject, PutObject]");
        Check.check("ListAccessPointsForDirectoryBuckets", ctl.listAccessPointsForDirectoryBuckets(r -> r.accountId(account)
            .directoryBucket(bucket)).accessPointList().stream().map(a -> a.name()).toList(), List.of(door));
        d.putObject(r -> r.bucket(door).key("pub/a.txt"), RequestBody.fromString("through"));
        Check.check("a GET through it", d.getObjectAsBytes(r -> r.bucket(door).key("pub/a.txt")).asUtf8String(), "through");
        Check.check("a key outside its scope", Directory.codeOf(() -> d.getObjectAsBytes(r -> r.bucket(door).key("other/a.txt"))),
            "AccessDenied");
        Check.check("a permission outside its scope", Directory.codeOf(() -> d.deleteObject(r -> r.bucket(door).key("pub/a.txt"))),
            "AccessDenied");
        ctl.deleteAccessPoint(r -> r.accountId(account).name(door));
        d.deleteObject(r -> r.bucket(bucket).key("pub/a.txt"));
        d.deleteBucket(r -> r.bucket(bucket));
    }
}
