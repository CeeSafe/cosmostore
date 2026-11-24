import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import org.apache.iceberg.DataFile;
import org.apache.iceberg.DeleteFile;
import org.apache.iceberg.FileFormat;
import org.apache.iceberg.FileScanTask;
import org.apache.iceberg.PartitionSpec;
import org.apache.iceberg.Schema;
import org.apache.iceberg.Snapshot;
import org.apache.iceberg.Table;
import org.apache.iceberg.TableMetadata;
import org.apache.iceberg.HasTableOperations;
import org.apache.iceberg.catalog.Namespace;
import org.apache.iceberg.catalog.TableIdentifier;
import org.apache.iceberg.data.GenericRecord;
import org.apache.iceberg.data.IcebergGenerics;
import org.apache.iceberg.data.Record;
import org.apache.iceberg.data.parquet.GenericParquetWriter;
import org.apache.iceberg.deletes.BaseDVFileWriter;
import org.apache.iceberg.io.CloseableIterable;
import org.apache.iceberg.io.DataWriter;
import org.apache.iceberg.io.DeleteWriteResult;
import org.apache.iceberg.io.OutputFile;
import org.apache.iceberg.io.OutputFileFactory;
import org.apache.iceberg.parquet.Parquet;
import org.apache.iceberg.rest.RESTCatalog;
import org.apache.iceberg.types.Types;

/**
 * Iceberg Java's v3 table against `cosmostore serve` (ADR-0122 slice 6).
 *
 * <p>{@code create}: a v3 table made by the REST catalog (its compaction then disabled by the check, so that its
 * files stay as written until it is enabled).
 *
 * <p>{@code write}: three files appended, and a deletion vector of the first
 * file's positions 0 and 1 written by Iceberg's own {@code BaseDVFileWriter} and committed as a row delta. It prints
 * each live row as {@code row <id> <row id>}: a file's first row id plus the row's position.
 *
 * <p>{@code read}: the table read back by Iceberg's generic reader; prints {@code id <id>} per row, the table's
 * format version, next row id, and the current snapshot's operation and first row id.
 *
 * <p>usage: java V3Check ENDPOINT WAREHOUSE_ARN create|upgrade|write|read (AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY set)
 */
public class V3Check {
    static final Schema SCHEMA = new Schema(
        Types.NestedField.required(1, "id", Types.LongType.get()),
        Types.NestedField.optional(2, "data", Types.StringType.get()));

    static RESTCatalog catalog(String endpoint, String warehouse) {
        Map<String, String> p = new HashMap<>();
        p.put("uri", endpoint + "/iceberg");
        p.put("warehouse", warehouse);
        p.put("rest.sigv4-enabled", "true");
        p.put("rest.signing-name", "s3tables");
        p.put("rest.signing-region", "us-east-1");
        p.put("io-impl", "org.apache.iceberg.aws.s3.S3FileIO");
        p.put("s3.endpoint", endpoint);
        p.put("s3.path-style-access", "true");
        p.put("client.region", "us-east-1");
        p.put("s3.access-key-id", System.getenv("AWS_ACCESS_KEY_ID"));
        p.put("s3.secret-access-key", System.getenv("AWS_SECRET_ACCESS_KEY"));
        p.put("rest.access-key-id", System.getenv("AWS_ACCESS_KEY_ID"));
        p.put("rest.secret-access-key", System.getenv("AWS_SECRET_ACCESS_KEY"));
        RESTCatalog c = new RESTCatalog();
        c.initialize("cosmo", p);
        return c;
    }

    static DataFile writeFile(Table table, long first, int rows) throws Exception {
        OutputFile out = table.io().newOutputFile(table.locationProvider().newDataLocation(UUID.randomUUID() + ".parquet"));
        DataWriter<Record> w = Parquet.writeData(out)
            .schema(SCHEMA)
            .createWriterFunc(GenericParquetWriter::create)
            .overwrite()
            .withSpec(PartitionSpec.unpartitioned())
            .build();
        try (w) {
            for (int i = 0; i < rows; i++) {
                GenericRecord r = GenericRecord.create(SCHEMA);
                r.setField("id", first + i);
                r.setField("data", "row " + (first + i));
                w.write(r);
            }
        }
        return w.toDataFile();
    }

    public static void main(String[] args) throws Exception {
        RESTCatalog c = catalog(args[0], args[1]);
        TableIdentifier name = TableIdentifier.of(Namespace.of("javans"), "v3");
        if (args[2].equals("create")) {
            c.createNamespace(Namespace.of("javans"));
            Table table = c.buildTable(name, SCHEMA)
                .withPartitionSpec(PartitionSpec.unpartitioned())
                .withProperty("format-version", "3")
                .create();
            System.out.println("format " + ((HasTableOperations) table).operations().current().formatVersion());
        } else if (args[2].equals("upgrade")) {
            // A v2 table upgraded to v3 by its `format-version` property, as Iceberg Java sends it.
            TableIdentifier v2 = TableIdentifier.of(Namespace.of("javans"), "upgraded");
            Table table = c.buildTable(v2, SCHEMA).withProperty("format-version", "2").create();
            System.out.println("before " + ((HasTableOperations) table).operations().current().formatVersion());
            table.updateProperties().set("format-version", "3").commit();
            table.refresh();
            TableMetadata m = ((HasTableOperations) table).operations().current();
            System.out.println("format " + m.formatVersion());
            System.out.println("next-row-id " + m.nextRowId());
            table.newAppend().appendFile(writeFile(table, 0, 5)).commit();
            table.refresh();
            System.out.println("first-row-id " + table.currentSnapshot().firstRowId());
            System.out.println("after-append " + ((HasTableOperations) table).operations().current().nextRowId());
        } else if (args[2].equals("write")) {
            Table table = c.loadTable(name);
            for (int f = 0; f < 3; f++) {
                table.newAppend().appendFile(writeFile(table, f * 100, 10)).commit();
            }
            table.refresh();
            // A deletion vector of the first file's positions 0 and 1, by Iceberg's own writer.
            List<DataFile> files = new ArrayList<>();
            for (FileScanTask t : table.newScan().planFiles()) files.add(t.file());
            files.sort((a, b) -> Long.compare(a.firstRowId(), b.firstRowId()));
            DataFile victim = files.get(0);
            OutputFileFactory factory = OutputFileFactory.builderFor(table, 1, 1).format(FileFormat.PUFFIN).build();
            BaseDVFileWriter dv = new BaseDVFileWriter(factory, path -> null);
            dv.delete(victim.location(), 0L, table.spec(), null);
            dv.delete(victim.location(), 1L, table.spec(), null);
            dv.close();
            DeleteWriteResult result = dv.result();
            var delta = table.newRowDelta();
            for (DeleteFile d : result.deleteFiles()) delta.addDeletes(d);
            delta.commit();
            table.refresh();
            // Each live row's id: its file's first row id plus its position. Files were appended in order, each of
            // ids 100 * f to 100 * f + 9, written in id order.
            for (int f = 0; f < files.size(); f++) {
                long firstId = files.get(f).firstRowId();
                for (int i = 0; i < 10; i++) {
                    if (f == 0 && i < 2) continue;
                    System.out.println("row " + (f * 100 + i) + " " + (firstId + i));
                }
            }
            print(table);
        } else {
            Table table = c.loadTable(name);
            try (CloseableIterable<Record> rows = IcebergGenerics.read(table).build()) {
                for (Record r : rows) System.out.println("id " + r.getField("id"));
            }
            print(table);
        }
    }

    static void print(Table table) {
        TableMetadata m = ((HasTableOperations) table).operations().current();
        Snapshot s = table.currentSnapshot();
        System.out.println("format " + m.formatVersion());
        System.out.println("next-row-id " + m.nextRowId());
        System.out.println("operation " + s.operation());
        System.out.println("first-row-id " + s.firstRowId());
        int deletes = 0;
        for (FileScanTask t : table.newScan().planFiles()) deletes += t.deletes().size();
        System.out.println("deletes " + deletes);
    }
}
