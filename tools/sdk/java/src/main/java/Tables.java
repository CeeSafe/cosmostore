// S3 Tables (ADR-0083) through the AWS SDK for Java v2: table buckets, namespaces and tables, and the metadata
// location's compare-and-set on the versionToken.
import java.net.URI;
import java.util.List;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3tables.S3TablesClient;
import software.amazon.awssdk.services.s3tables.model.OpenTableFormat;

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
        Check.check("GetTableMaintenanceConfiguration: compaction off",
            tm.configurationAsStrings().get("icebergCompaction").statusAsString(), "disabled");
        var js = t.getTableMaintenanceJobStatus(r -> r.tableBucketARN(arn).namespace("sales").name("orders2"));
        Check.check("GetTableMaintenanceJobStatus", js.statusAsStrings().get("icebergCompaction").statusAsString(), "Disabled");
        t.deleteTable(r -> r.tableBucketARN(arn).namespace("sales").name("orders2"));
        t.deleteNamespace(r -> r.tableBucketARN(arn).namespace("sales"));
        t.deleteTableBucket(r -> r.tableBucketARN(arn));
        Check.check("DeleteTableBucket", t.listTableBuckets(r -> {}).tableBuckets().size(), 0);
    }
}
