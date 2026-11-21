// The IAM API (ADR-0104) through the AWS SDK for Java v2: a user, its key and policy; the key signs within an upkeep
// round (10 s here); a role made with a trust policy and assumed; everything deleted, and the key refused after.
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.function.Supplier;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.AwsSessionCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.awscore.exception.AwsServiceException;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.iam.IamClient;
import software.amazon.awssdk.services.iam.model.AccessKey;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.sts.StsClient;
import software.amazon.awssdk.services.sts.model.Credentials;

class Iam {
    static final String B = "sdk-java-iam";

    // Polls `fn` every 250 ms until it is true or `seconds` pass.
    static boolean within(int seconds, Supplier<Boolean> fn) {
        long end = System.currentTimeMillis() + seconds * 1000L;
        while (System.currentTimeMillis() < end) {
            if (fn.get()) return true;
            try { Thread.sleep(250); } catch (InterruptedException e) { return false; }
        }
        return false;
    }

    // Any service's error code, as Check.codeOf gives S3's.
    static String codeOf(Runnable r) {
        try {
            r.run();
            return "no error";
        } catch (AwsServiceException e) {
            return e.awsErrorDetails().errorCode() == null ? String.valueOf(e.statusCode()) : e.awsErrorDetails().errorCode();
        }
    }

    static String reads(S3Client c) {
        try {
            return c.getObjectAsBytes(r -> r.bucket(B).key("a")).asUtf8String();
        } catch (RuntimeException e) {
            return codeOf(() -> { throw e; });
        }
    }

    static void run(URI endpoint) {
        S3Client account = S3Client.builder().endpointOverride(endpoint).region(Region.US_EAST_1).forcePathStyle(true).build();
        account.createBucket(r -> r.bucket(B));
        account.putObject(r -> r.bucket(B).key("a"), RequestBody.fromString("read me"));
        IamClient iam = IamClient.builder().endpointOverride(endpoint).region(Region.AWS_GLOBAL).build();
        Check.check("iam CreateUser", iam.createUser(r -> r.userName("java-dev")).user().userName(), "java-dev");
        Check.check("iam a name twice", codeOf(() -> iam.createUser(r -> r.userName("java-dev"))), "EntityAlreadyExists");
        AccessKey made = iam.createAccessKey(r -> r.userName("java-dev")).accessKey();
        Check.check("iam CreateAccessKey", made.accessKeyId().substring(0, 4) + " " + (made.secretAccessKey().length() >= 40), "AKIA true");
        Check.check("iam ListAccessKeys", iam.listAccessKeys(r -> r.userName("java-dev")).accessKeyMetadata().get(0).accessKeyId(), made.accessKeyId());
        String policy = "{\"Version\":\"2012-10-17\",\"Statement\":{\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::" + B + "/*\"}}";
        iam.putUserPolicy(r -> r.userName("java-dev").policyName("reads").policyDocument(policy));
        String doc = URLDecoder.decode(iam.getUserPolicy(r -> r.userName("java-dev").policyName("reads")).policyDocument(), StandardCharsets.UTF_8);
        Check.check("iam GetUserPolicy", doc.contains("\"Action\":\"s3:GetObject\""), true);
        S3Client dev = S3Client.builder().endpointOverride(endpoint).region(Region.US_EAST_1).forcePathStyle(true)
            .credentialsProvider(StaticCredentialsProvider.create(AwsBasicCredentials.create(made.accessKeyId(), made.secretAccessKey())))
            .build();
        Check.check("iam its key reads within a round", within(25, () -> reads(dev).equals("read me")), true);
        Check.check("iam and no more", codeOf(() -> dev.putObject(r -> r.bucket(B).key("no"), RequestBody.fromString("no"))), "AccessDenied");
        String trust = "{\"Version\":\"2012-10-17\",\"Statement\":{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::000000000000:root\"},\"Action\":\"sts:AssumeRole\"}}";
        Check.check("iam CreateRole", iam.createRole(r -> r.roleName("java-role").assumeRolePolicyDocument(trust)).role().arn(),
            "arn:aws:iam::000000000000:role/java-role");
        String trustRead = URLDecoder.decode(iam.getRole(r -> r.roleName("java-role")).role().assumeRolePolicyDocument(), StandardCharsets.UTF_8);
        Check.check("iam its trust read back", trustRead.contains("\"AWS\":\"arn:aws:iam::000000000000:root\""), true);
        iam.putRolePolicy(r -> r.roleName("java-role").policyName("reads").policyDocument(policy));
        StsClient sts = StsClient.builder().endpointOverride(endpoint).region(Region.US_EAST_1).build();
        Credentials[] assumed = new Credentials[1];
        within(25, () -> {
            try {
                assumed[0] = sts.assumeRole(r -> r.roleArn("arn:aws:iam::000000000000:role/java-role").roleSessionName("java")).credentials();
                return true;
            } catch (RuntimeException e) {
                return false;
            }
        });
        Check.check("iam the role assumed", assumed[0] != null && assumed[0].accessKeyId().startsWith("ASIA"), true);
        if (assumed[0] != null) {
            Credentials c = assumed[0];
            S3Client session = S3Client.builder().endpointOverride(endpoint).region(Region.US_EAST_1).forcePathStyle(true)
                .credentialsProvider(StaticCredentialsProvider.create(
                    AwsSessionCredentials.create(c.accessKeyId(), c.secretAccessKey(), c.sessionToken())))
                .build();
            Check.check("iam its session reads", reads(session), "read me");
        }
        Check.check("iam a user with keys not deleted", codeOf(() -> iam.deleteUser(r -> r.userName("java-dev"))), "DeleteConflict");
        iam.deleteAccessKey(r -> r.userName("java-dev").accessKeyId(made.accessKeyId()));
        iam.deleteUserPolicy(r -> r.userName("java-dev").policyName("reads"));
        iam.deleteUser(r -> r.userName("java-dev"));
        iam.deleteRolePolicy(r -> r.roleName("java-role").policyName("reads"));
        iam.deleteRole(r -> r.roleName("java-role"));
        Check.check("iam the user gone", codeOf(() -> iam.getUser(r -> r.userName("java-dev"))), "NoSuchEntity");
        Check.check("iam its key refused within a round", within(25, () -> reads(dev).equals("InvalidAccessKeyId")), true);
        account.deleteObject(r -> r.bucket(B).key("a"));
        account.deleteBucket(r -> r.bucket(B));
    }
}
