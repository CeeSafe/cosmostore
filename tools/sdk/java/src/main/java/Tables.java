// S3 Tables (ADR-0083) through the AWS SDK for Java v2: table buckets, namespaces and tables, and the metadata
// location's compare-and-set on the versionToken.
import java.net.URI;
import java.util.List;
import java.util.Map;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3tables.S3TablesClient;
import software.amazon.awssdk.services.s3tables.model.OpenTableFormat;
import software.amazon.awssdk.services.s3tables.model.SSEAlgorithm;
import software.amazon.awssdk.services.s3tables.model.StorageClass;

class Tables {
    static void run(URI endpoint) {
        S3TablesClient t = S3TablesClient.builder().endpointOverride(endpoint).region(Region.US_EAST_1).build();
        S3Client s = S3Client.builder().endpointOverride(endpoint).region(Region.US_EAST_1).forcePathStyle(true).build();
        String arn = t.createTableBucket(r -> r.name("sdk-java-tables")).arn();
        Check.check("CreateTableBucket", arn, "arn:aws:s3tables:us-east-1:000000000000:bucket/sdk-java-tables");
        Check.check("ListTableBuckets", t.listTableBuckets(r -> {}).tableBuckets().stream().map(b -> b.name()).toList(),
            List.of("sdk-java-tables"));
        t.createNamespace(r -> r.tableBucketARN(arn).namespace("sales"));
        String tableArn = t.createTable(r -> r.tableBucketARN(arn).namespace("sales").name("orders").format(OpenTableFormat.ICEBERG))
            .tableARN();
        var got = t.getTable(r -> r.tableArn(tableArn));
        Check.check("GetTable by its ARN", got.name(), "orders");
        String wh = got.warehouseLocation();
        String[] parts = wh.substring(5).split("/", 2);
        s.putObject(r -> r.bucket(parts[0]).key(parts[1] + "/metadata/00001-v.metadata.json"), RequestBody.fromString("{}"));
        var moved = t.updateTableMetadataLocation(r -> r.tableBucketARN(arn).namespace("sales").name("orders")
            .versionToken(got.versionToken()).metadataLocation(wh + "/metadata/00001-v.metadata.json"));
        Check.check("UpdateTableMetadataLocation", moved.metadataLocation(), wh + "/metadata/00001-v.metadata.json");
        Check.check("a stale versionToken", Directory.codeOf(() -> t.updateTableMetadataLocation(r -> r.tableBucketARN(arn)
            .namespace("sales").name("orders").versionToken(got.versionToken()).metadataLocation(wh + "/metadata/00002-v.metadata.json"))),
            "ConflictException");
        t.renameTable(r -> r.tableBucketARN(arn).namespace("sales").name("orders").newName("orders2"));
        Check.check("RenameTable", t.listTables(r -> r.tableBucketARN(arn)).tables().stream().map(x -> x.name()).toList(),
            List.of("orders2"));
        // Maintenance (ADR-0086): a table bucket's configuration put and read back; compaction is not done.
        t.putTableBucketMaintenanceConfiguration(r -> r.tableBucketARN(arn).type("icebergUnreferencedFileRemoval")
            .value(v -> v.status("enabled").settings(st -> st.icebergUnreferencedFileRemoval(u -> u.unreferencedDays(4).nonCurrentDays(9)))));
        var bm = t.getTableBucketMaintenanceConfiguration(r -> r.tableBucketARN(arn));
        Check.check("GetTableBucketMaintenanceConfiguration",
            bm.configurationAsStrings().get("icebergUnreferencedFileRemoval").settings().icebergUnreferencedFileRemoval().unreferencedDays(), 4);
        var tm = t.getTableMaintenanceConfiguration(r -> r.tableBucketARN(arn).namespace("sales").name("orders2"));
        Check.check("GetTableMaintenanceConfiguration: compaction on by default",
            tm.configurationAsStrings().get("icebergCompaction").statusAsString(), "enabled");
        var js = t.getTableMaintenanceJobStatus(r -> r.tableBucketARN(arn).namespace("sales").name("orders2"));
        Check.check("GetTableMaintenanceJobStatus", js.statusAsStrings().get("icebergCompaction").statusAsString(), "Not_Yet_Run");
        t.deleteTable(r -> r.tableBucketARN(arn).namespace("sales").name("orders2"));
        t.deleteNamespace(r -> r.tableBucketARN(arn).namespace("sales"));
        t.deleteTableBucket(r -> r.tableBucketARN(arn));
        Check.check("DeleteTableBucket", t.listTableBuckets(r -> {}).tableBuckets().size(), 0);
        // Tags, storage class and encryption (ADR-0126): given at create, changed after; a table takes its bucket's
        // storage class and encryption when it is made and keeps them.
        String carn = t.createTableBucket(r -> r.name("sdk-java-config").tags(Map.of("team", "data"))
            .storageClassConfiguration(c -> c.storageClass(StorageClass.INTELLIGENT_TIERING))
            .encryptionConfiguration(e -> e.sseAlgorithm(SSEAlgorithm.AES256))).arn();
        Check.check("CreateTableBucket with tags", t.listTagsForResource(r -> r.resourceArn(carn)).tags(), Map.of("team", "data"));
        t.tagResource(r -> r.resourceArn(carn).tags(Map.of("env", "test")));
        t.untagResource(r -> r.resourceArn(carn).tagKeys("team"));
        Check.check("TagResource and UntagResource", t.listTagsForResource(r -> r.resourceArn(carn)).tags(), Map.of("env", "test"));
        Check.check("GetTableBucketStorageClass",
            t.getTableBucketStorageClass(r -> r.tableBucketARN(carn)).storageClassConfiguration().storageClassAsString(), "INTELLIGENT_TIERING");
        Check.check("GetTableBucketEncryption",
            t.getTableBucketEncryption(r -> r.tableBucketARN(carn)).encryptionConfiguration().sseAlgorithmAsString(), "AES256");
        t.createNamespace(r -> r.tableBucketARN(carn).namespace("ns"));
        String carnT = t.createTable(r -> r.tableBucketARN(carn).namespace("ns").name("t").format(OpenTableFormat.ICEBERG)).tableARN();
        Check.check("GetTableStorageClass: the bucket's",
            t.getTableStorageClass(r -> r.tableBucketARN(carn).namespace("ns").name("t")).storageClassConfiguration().storageClassAsString(),
            "INTELLIGENT_TIERING");
        Check.check("GetTableEncryption: the bucket's",
            t.getTableEncryption(r -> r.tableBucketARN(carn).namespace("ns").name("t")).encryptionConfiguration().sseAlgorithmAsString(), "AES256");
        Check.check("a table's tags: none", t.listTagsForResource(r -> r.resourceArn(carnT)).tags(), Map.of());
        t.putTableBucketStorageClass(r -> r.tableBucketARN(carn).storageClassConfiguration(c -> c.storageClass(StorageClass.STANDARD)));
        Check.check("PutTableBucketStorageClass",
            t.getTableBucketStorageClass(r -> r.tableBucketARN(carn)).storageClassConfiguration().storageClassAsString(), "STANDARD");
        Check.check("a table keeps its storage class",
            t.getTableStorageClass(r -> r.tableBucketARN(carn).namespace("ns").name("t")).storageClassConfiguration().storageClassAsString(),
            "INTELLIGENT_TIERING");
        t.deleteTableBucketEncryption(r -> r.tableBucketARN(carn));
        Check.check("DeleteTableBucketEncryption",
            Directory.codeOf(() -> t.getTableBucketEncryption(r -> r.tableBucketARN(carn))).equals("no error"), false);
        Check.check("a table keeps its encryption",
            t.getTableEncryption(r -> r.tableBucketARN(carn).namespace("ns").name("t")).encryptionConfiguration().sseAlgorithmAsString(), "AES256");
        t.deleteTable(r -> r.tableBucketARN(carn).namespace("ns").name("t"));
        t.deleteNamespace(r -> r.tableBucketARN(carn).namespace("ns"));
        t.deleteTableBucket(r -> r.tableBucketARN(carn));
        Check.check("DeleteTableBucket: configured", t.listTableBuckets(r -> {}).tableBuckets().size(), 0);
        // Metrics and record expiration (ADR-0130): a table bucket's metrics configuration put, read and deleted; record
        // expiration is not offered. The SDK's 2.57.11 has no PutTableBucketLogging or GetTableBucketLogging, so the
        // logging configuration is checked by the .NET SDK.
        String larn = t.createTableBucket(r -> r.name("sdk-java-logged")).arn();
        Check.check("GetTableBucketMetricsConfiguration: none",
            Directory.codeOf(() -> t.getTableBucketMetricsConfiguration(r -> r.tableBucketARN(larn))), "NotFoundException");
        t.putTableBucketMetricsConfiguration(r -> r.tableBucketARN(larn));
        var mc = t.getTableBucketMetricsConfiguration(r -> r.tableBucketARN(larn));
        Check.check("PutTableBucketMetricsConfiguration", mc.tableBucketARN() + " " + !mc.id().isEmpty(), larn + " true");
        t.deleteTableBucketMetricsConfiguration(r -> r.tableBucketARN(larn));
        Check.check("DeleteTableBucketMetricsConfiguration",
            Directory.codeOf(() -> t.getTableBucketMetricsConfiguration(r -> r.tableBucketARN(larn))), "NotFoundException");
        t.createNamespace(r -> r.tableBucketARN(larn).namespace("ns"));
        String larnT = t.createTable(r -> r.tableBucketARN(larn).namespace("ns").name("t").format(OpenTableFormat.ICEBERG)).tableARN();
        Check.check("GetTableRecordExpirationConfiguration: not offered",
            Directory.codeOf(() -> t.getTableRecordExpirationConfiguration(r -> r.tableArn(larnT))), "MethodNotAllowedException");
        Check.check("GetTableRecordExpirationJobStatus: not offered",
            Directory.codeOf(() -> t.getTableRecordExpirationJobStatus(r -> r.tableArn(larnT))), "MethodNotAllowedException");
        t.deleteTable(r -> r.tableBucketARN(larn).namespace("ns").name("t"));
        t.deleteNamespace(r -> r.tableBucketARN(larn).namespace("ns"));
        t.deleteTableBucket(r -> r.tableBucketARN(larn));
        Check.check("DeleteTableBucket: with metrics", t.listTableBuckets(r -> {}).tableBuckets().size(), 0);
    }
}
