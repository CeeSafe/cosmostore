// M7 (ADR-0072 to ADR-0077) through the AWS SDK for Java v2: each item's configuration calls and what each does.
// common.sh starts serve with access logs every 2 s, a 3 s inventory day, websites under web.localhost and a role
// "reader" of sdk-m7.
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Socket;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.function.BooleanSupplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.GZIPInputStream;
import software.amazon.awssdk.auth.credentials.AwsSessionCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.awscore.exception.AwsServiceException;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.*;
import software.amazon.awssdk.services.s3control.S3ControlClient;
import software.amazon.awssdk.services.sts.StsClient;
import software.amazon.awssdk.services.sts.model.Credentials;
import software.amazon.awssdk.services.sts.model.PolicyDescriptorType;

class M7 {
    static final String ACCOUNT = "000000000000";

    static String codeOf(Runnable r) {
        try {
            r.run();
            return "no error";
        } catch (AwsServiceException e) {
            return e.awsErrorDetails().errorCode() == null ? String.valueOf(e.statusCode()) : e.awsErrorDetails().errorCode();
        }
    }

    static boolean until(int seconds, BooleanSupplier f) throws InterruptedException {
        long end = System.currentTimeMillis() + seconds * 1000L;
        while (System.currentTimeMillis() < end) {
            if (f.getAsBoolean()) return true;
            Thread.sleep(250);
        }
        return false;
    }

    static List<String> keysUnder(S3Client s3, String bucket, String prefix) {
        return s3.listObjectsV2(r -> r.bucket(bucket).prefix(prefix)).contents().stream().map(S3Object::key).toList();
    }

    static String read(S3Client c, String bucket, String key) {
        try {
            return c.getObjectAsBytes(r -> r.bucket(bucket).key(key)).asUtf8String();
        } catch (AwsServiceException e) {
            return e.awsErrorDetails().errorCode();
        }
    }

    /** A GET with another Host, which java.net.http does not let a client set: one HTTP/1.1 request on a socket. */
    static String page(URI endpoint, String host, String path) throws Exception {
        try (Socket s = new Socket(endpoint.getHost(), endpoint.getPort())) {
            OutputStream out = s.getOutputStream();
            out.write(("GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
            out.flush();
            String text = new String(s.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
            String status = text.split(" ", 3)[1];
            return status + " " + text.substring(text.indexOf("\r\n\r\n") + 4);
        }
    }

    static void run(URI endpoint, S3Client s3) throws Exception {
        String m = "sdk-m7", logs = "sdk-m7-logs";
        s3.createBucket(r -> r.bucket(m));
        s3.createBucket(r -> r.bucket(logs));
        s3.putObject(r -> r.bucket(m).key("index.html").contentType("text/html"), RequestBody.fromString("the index"));
        s3.putObject(r -> r.bucket(m).key("error.html").contentType("text/html"), RequestBody.fromString("the error page"));

        // Access logs (ADR-0072).
        s3.putBucketLogging(r -> r.bucket(m).bucketLoggingStatus(s -> s.loggingEnabled(l -> l.targetBucket(logs).targetPrefix("access/"))));
        LoggingEnabled lg = s3.getBucketLogging(r -> r.bucket(m)).loggingEnabled();
        Check.check("GetBucketLogging", lg.targetBucket() + " " + lg.targetPrefix(), logs + " access/");
        Check.check("logging to a bucket that is not there", codeOf(() -> s3.putBucketLogging(r -> r.bucket(m).bucketLoggingStatus(s ->
            s.loggingEnabled(l -> l.targetBucket("sdk-nowhere").targetPrefix("x/"))))), "InvalidTargetBucketForLogging");
        s3.putObject(r -> r.bucket(m).key("logged.txt"), RequestBody.fromString("logged"));
        Check.check("the PUT's line in a log object", until(15, () -> keysUnder(s3, logs, "access/").stream()
            .anyMatch(k -> read(s3, logs, k).contains("REST.PUT.OBJECT logged.txt"))), true);
        s3.putBucketLogging(r -> r.bucket(m).bucketLoggingStatus(BucketLoggingStatus.builder().build()));
        Check.check("logging off", s3.getBucketLogging(r -> r.bucket(m)).loggingEnabled(), null);

        // Website hosting (ADR-0073), through <bucket>.web.localhost, with a policy that lets anyone read.
        s3.putBucketWebsite(r -> r.bucket(m).websiteConfiguration(w -> w.indexDocument(i -> i.suffix("index.html"))
            .errorDocument(e -> e.key("error.html"))));
        GetBucketWebsiteResponse ws = s3.getBucketWebsite(r -> r.bucket(m));
        Check.check("GetBucketWebsite", ws.indexDocument().suffix() + " " + ws.errorDocument().key(), "index.html error.html");
        s3.putBucketPolicy(r -> r.bucket(m).policy(
            "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::sdk-m7/*\"}]}"));
        String host = m + ".web.localhost:" + endpoint.getPort();
        Check.check("the site's index", page(endpoint, host, "/"), "200 the index");
        Check.check("the site's error document", page(endpoint, host, "/no-such-page"), "404 the error page");
        s3.deleteBucketWebsite(r -> r.bucket(m));
        Check.check("the website deleted", codeOf(() -> s3.getBucketWebsite(r -> r.bucket(m))), "NoSuchWebsiteConfiguration");
        s3.deleteBucketPolicy(r -> r.bucket(m));

        // Inventory (ADR-0074): a daily CSV report into the logs bucket; a day is 3 s here.
        s3.putBucketInventoryConfiguration(r -> r.bucket(m).id("daily").inventoryConfiguration(c -> c.id("daily").isEnabled(true)
            .includedObjectVersions(InventoryIncludedObjectVersions.CURRENT).schedule(s -> s.frequency(InventoryFrequency.DAILY))
            .destination(d -> d.s3BucketDestination(sd -> sd.bucket("arn:aws:s3:::" + logs).format(InventoryFormat.CSV).prefix("inv")))));
        InventoryConfiguration inv = s3.getBucketInventoryConfiguration(r -> r.bucket(m).id("daily")).inventoryConfiguration();
        Check.check("GetBucketInventoryConfiguration", inv.id() + " " + inv.isEnabled() + " " + inv.schedule().frequencyAsString() + " "
            + inv.destination().s3BucketDestination().bucket(), "daily true Daily arn:aws:s3:::" + logs);
        Check.check("ListBucketInventoryConfigurations",
            s3.listBucketInventoryConfigurations(r -> r.bucket(m)).inventoryConfigurationList().size(), 1);
        Check.check("an account id is not done, not dropped", codeOf(() -> s3.putBucketInventoryConfiguration(r -> r.bucket(m).id("acct")
            .inventoryConfiguration(c -> c.id("acct").isEnabled(true).includedObjectVersions(InventoryIncludedObjectVersions.CURRENT)
                .schedule(s -> s.frequency(InventoryFrequency.DAILY)).destination(d -> d.s3BucketDestination(sd ->
                    sd.bucket("arn:aws:s3:::" + logs).format(InventoryFormat.CSV).accountId("111122223333")))))), "NotImplemented");
        String[] manifest = {null};
        until(20, () -> (manifest[0] = keysUnder(s3, logs, "inv/").stream().filter(k -> k.endsWith("manifest.json")).findFirst()
            .orElse(null)) != null);
        Check.check("a report's manifest", manifest[0] != null, true);
        if (manifest[0] != null) {
            String doc = read(s3, logs, manifest[0]);
            Matcher key = Pattern.compile("\"files\"\\s*:\\s*\\[\\s*\\{[^}]*\"key\"\\s*:\\s*\"([^\"]+)\"").matcher(doc);
            if (key.find()) {
                byte[] gz = s3.getObjectAsBytes(r -> r.bucket(logs).key(key.group(1))).asByteArray();
                String csv;
                try (InputStream in = new GZIPInputStream(new ByteArrayInputStream(gz))) {
                    csv = new String(in.readAllBytes(), StandardCharsets.UTF_8);
                }
                List<String> listed = csv.strip().lines().map(l -> l.split(",")[1].replace("\"", "")).sorted().toList();
                Check.check("its CSV has every object", String.join(" ", listed), "error.html index.html logged.txt");
            } else {
                Check.check("its manifest names a file", doc, "a file");
            }
        }
        s3.deleteBucketInventoryConfiguration(r -> r.bucket(m).id("daily"));
        Check.check("the inventory deleted", codeOf(() -> s3.getBucketInventoryConfiguration(r -> r.bucket(m).id("daily"))),
            "NoSuchConfiguration");

        // STS (ADR-0075): a session token, and the role "reader", sign S3 requests.
        StsClient sts = StsClient.builder().endpointOverride(endpoint).region(Region.US_EAST_1).build();
        java.util.function.Function<Credentials, S3Client> as = c -> S3Client.builder().endpointOverride(endpoint).region(Region.US_EAST_1)
            .forcePathStyle(true).credentialsProvider(StaticCredentialsProvider.create(
                AwsSessionCredentials.create(c.accessKeyId(), c.secretAccessKey(), c.sessionToken()))).build();
        Credentials session = sts.getSessionToken(r -> r.durationSeconds(900)).credentials();
        Check.check("GetSessionToken gives an ASIA key", session.accessKeyId().substring(0, 4), "ASIA");
        Check.check("the session reads", read(as.apply(session), m, "logged.txt"), "logged");
        S3Client reader = as.apply(sts.assumeRole(r -> r.roleArn("arn:aws:iam::" + ACCOUNT + ":role/reader").roleSessionName("java")).credentials());
        Check.check("the role reads", read(reader, m, "logged.txt"), "logged");
        Check.check("the role does not write", codeOf(() -> reader.putObject(r -> r.bucket(m).key("no"), RequestBody.fromString("no"))), "AccessDenied");
        Check.check("nor read another bucket", codeOf(() -> reader.listObjectsV2(r -> r.bucket(logs))), "AccessDenied");
        Check.check("policy ARNs are not done, not dropped", codeOf(() -> sts.assumeRole(r -> r.roleArn("arn:aws:iam::" + ACCOUNT + ":role/reader")
            .roleSessionName("arns").policyArns(PolicyDescriptorType.builder().arn("arn:aws:iam::aws:policy/ReadOnlyAccess").build()))),
            "NotImplemented");

        // Access Points (ADR-0076): S3 Control puts the account in the host (`<account>.localhost`); a request by ARN
        // goes to `<name>-<account>.localhost`.
        URI local = URI.create(endpoint.toString().replace("127.0.0.1", "localhost"));
        S3ControlClient ctl = S3ControlClient.builder().endpointOverride(local).region(Region.US_EAST_1).build();
        String alias = ctl.createAccessPoint(r -> r.accountId(ACCOUNT).name("sdk-ap").bucket(m)).alias();
        Check.check("CreateAccessPoint gives an alias", alias != null && alias.endsWith("-s3alias"), true);
        var ap = ctl.getAccessPoint(r -> r.accountId(ACCOUNT).name("sdk-ap"));
        Check.check("GetAccessPoint", ap.bucket() + " " + ap.networkOriginAsString(), m + " Internet");
        Check.check("ListAccessPoints", ctl.listAccessPoints(r -> r.accountId(ACCOUNT).bucket(m)).accessPointList().size(), 1);
        Check.check("a name twice", codeOf(() -> ctl.createAccessPoint(r -> r.accountId(ACCOUNT).name("sdk-ap").bucket(m))),
            "AccessPointAlreadyOwnedByYou");
        s3.putObject(r -> r.bucket(alias).key("ap/door.txt"), RequestBody.fromString("through a door"));
        Check.check("a write by its alias lands in its bucket", read(s3, m, "ap/door.txt"), "through a door");
        S3Client hosted = S3Client.builder().endpointOverride(local).region(Region.US_EAST_1).forcePathStyle(false).build();
        Check.check("a read by its ARN", read(hosted, "arn:aws:s3:us-east-1:" + ACCOUNT + ":accesspoint/sdk-ap", "ap/door.txt"), "through a door");
        ctl.deleteAccessPoint(r -> r.accountId(ACCOUNT).name("sdk-ap"));
        Check.check("the access point deleted", codeOf(() -> ctl.getAccessPoint(r -> r.accountId(ACCOUNT).name("sdk-ap"))), "NoSuchAccessPoint");

        // Replication (ADR-0077): a new version copied to another bucket with its version id and ETag.
        String rs = "sdk-rsrc", rd = "sdk-rdst";
        for (String bucket : List.of(rs, rd)) {
            s3.createBucket(r -> r.bucket(bucket));
            s3.putBucketVersioning(r -> r.bucket(bucket).versioningConfiguration(v -> v.status(BucketVersioningStatus.ENABLED)));
        }
        java.util.function.Function<String, ReplicationRule> rule = id -> ReplicationRule.builder().id(id).priority(1)
            .status(ReplicationRuleStatus.ENABLED).filter(f -> f.prefix("")).deleteMarkerReplication(d -> d.status(DeleteMarkerReplicationStatus.ENABLED))
            .destination(d -> d.bucket("arn:aws:s3:::" + rd)).build();
        String role = "arn:aws:iam::" + ACCOUNT + ":role/r";
        Check.check("one priority twice", codeOf(() -> s3.putBucketReplication(r -> r.bucket(rs).replicationConfiguration(c ->
            c.role(role).rules(rule.apply("all"), rule.apply("again"))))), "InvalidArgument");
        s3.putBucketReplication(r -> r.bucket(rs).replicationConfiguration(c -> c.role(role).rules(rule.apply("all"))));
        Check.check("GetBucketReplication", s3.getBucketReplication(r -> r.bucket(rs)).replicationConfiguration().rules().get(0).destination().bucket(),
            "arn:aws:s3:::" + rd);
        PutObjectResponse src = s3.putObject(r -> r.bucket(rs).key("r/one.txt"), RequestBody.fromString("replicate me"));
        Check.check("replicated", until(15, () -> "COMPLETED".equals(s3.headObject(r -> r.bucket(rs).key("r/one.txt")).replicationStatusAsString())), true);
        HeadObjectResponse replica = s3.headObject(r -> r.bucket(rd).key("r/one.txt"));
        Check.check("the replica keeps its version id and ETag", replica.versionId() + " " + replica.eTag(), src.versionId() + " " + src.eTag());
        Check.check("and is a replica", replica.replicationStatusAsString(), "REPLICA");
        s3.deleteBucketReplication(r -> r.bucket(rs));
        Check.check("the replication deleted", codeOf(() -> s3.getBucketReplication(r -> r.bucket(rs))), "ReplicationConfigurationNotFoundError");
    }
}
