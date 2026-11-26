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
 * <p>usage: java V3Check ENDPOINT WAREHOUSE_ARN create|upgrade|ctas|rtas|calls|write|read (AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY set)
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

    interface Call { void run() throws Exception; }

    static void call(String name, Call c) {
        try {
            c.run();
            System.out.println("call-" + name + " ok");
        } catch (Throwable e) {
            if (System.getenv("CALL_TRACES") != null) e.printStackTrace();
            System.out.println("call-" + name + " " + e.getClass().getSimpleName() + ":" + String.valueOf(e.getMessage()).replace(' ', '_'));
        }
    }

    static long count(Table table) throws Exception {
        long n = 0;
        try (CloseableIterable<Record> rows = IcebergGenerics.read(table).build()) {
            for (Record r : rows) n++;
        }
        return n;
    }

    static int countSnapshots(Table table) {
        int n = 0;
        for (Snapshot s : table.snapshots()) n++;
        return n;
    }

    /** A file of `rows` rows of `table`'s schema (its columns past the first two null). */
    static DataFile writeFileIn(Table table, long first, int rows) throws Exception {
        OutputFile out = table.io().newOutputFile(table.locationProvider().newDataLocation(UUID.randomUUID() + ".parquet"));
        DataWriter<Record> w = Parquet.writeData(out)
            .schema(table.schema())
            .createWriterFunc(GenericParquetWriter::create)
            .overwrite()
            .withSpec(table.spec())
            .build();
        try (w) {
            for (int i = 0; i < rows; i++) {
                GenericRecord r = GenericRecord.create(table.schema());
                r.setField("id", first + i);
                r.setField("data", "row " + (first + i));
                w.write(r);
            }
        }
        return w.toDataFile();
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
        } else if (args[2].equals("views")) {
            // Views and nested namespaces (ADR-0134), with Iceberg Java's view builder.
            TableIdentifier v = TableIdentifier.of(Namespace.of("javans"), "jview");
            c.buildView(v).withSchema(SCHEMA).withDefaultNamespace(Namespace.of("javans"))
                .withQuery("spark", "select id from javans.v3").withProperty("comment", "one").create();
            var view = c.loadView(v);
            System.out.println("view-sql " + view.sqlFor("spark").sql().replace(' ', '_'));
            c.buildView(v).withSchema(SCHEMA).withDefaultNamespace(Namespace.of("javans"))
                .withQuery("spark", "select id from javans.v3 where id > 1").replace();
            view = c.loadView(v);
            System.out.println("view-versions " + view.history().size());
            System.out.println("view-current " + view.currentVersion().versionId());
            System.out.println("views-listed " + c.listViews(Namespace.of("javans")).size());
            TableIdentifier moved = TableIdentifier.of(Namespace.of("javans"), "jview2");
            c.renameView(v, moved);
            System.out.println("view-renamed " + (c.viewExists(moved) && !c.viewExists(v)));
            System.out.println("view-dropped " + c.dropView(moved));
            Namespace nested = Namespace.of("jdeep", "er");
            c.createNamespace(Namespace.of("jdeep"));
            c.createNamespace(nested);
            TableIdentifier nt = TableIdentifier.of(nested, "t");
            Table table = c.createTable(nt, SCHEMA, PartitionSpec.unpartitioned(), Map.of("format-version", "2"));
            table.newAppend().appendFile(writeFileIn(table, 0, 3)).commit();
            System.out.println("nested-rows " + count(c.loadTable(nt)));
            System.out.println("nested-listed " + c.listNamespaces(Namespace.of("jdeep")).size());
            c.dropTable(nt, true);
            c.dropNamespace(nested);
            c.dropNamespace(Namespace.of("jdeep"));
        } else if (args[2].equals("ctas")) {
            // CREATE TABLE AS SELECT's way (ADR-0124): a staged create, its rows appended in the transaction, and the
            // table made by the transaction's one commit.
            TableIdentifier t = TableIdentifier.of(Namespace.of("javans"), "ctas");
            var tx = c.buildTable(t, SCHEMA).withProperty("format-version", "2").createTransaction();
            tx.newAppend().appendFile(writeFileIn(tx.table(), 0, 7)).commit();
            tx.commitTransaction();
            Table table = c.loadTable(t);
            System.out.println("ctas-rows " + count(table));
            System.out.println("ctas-snapshots " + countSnapshots(table));
        } else if (args[2].equals("rtas")) {
            // CREATE OR REPLACE TABLE AS SELECT's way: the table replaced (a new schema, its old rows gone, its history
            // kept), its new rows appended in the transaction.
            TableIdentifier t = TableIdentifier.of(Namespace.of("javans"), "ctas");
            Schema wider = new Schema(
                Types.NestedField.required(1, "id", Types.LongType.get()),
                Types.NestedField.optional(2, "data", Types.StringType.get()),
                Types.NestedField.optional(3, "extra", Types.IntegerType.get()));
            var tx = c.buildTable(t, wider).replaceTransaction();
            tx.newAppend().appendFile(writeFileIn(tx.table(), 1000, 3)).commit();
            tx.commitTransaction();
            Table table = c.loadTable(t);
            System.out.println("rtas-rows " + count(table));
            System.out.println("rtas-columns " + table.schema().columns().size());
            System.out.println("rtas-snapshots " + countSnapshots(table));
            // createOrReplace, both ways: of a table that is not there, then of the one it made.
            TableIdentifier fresh = TableIdentifier.of(Namespace.of("javans"), "cor");
            for (int k = 0; k < 2; k++) {
                var cor = c.buildTable(fresh, SCHEMA).createOrReplaceTransaction();
                cor.newAppend().appendFile(writeFileIn(cor.table(), k * 10, 2)).commit();
                cor.commitTransaction();
            }
            System.out.println("cor-rows " + count(c.loadTable(fresh)));
        } else if (args[2].equals("calls")) {
            // Each other catalog call Iceberg Java's REST client makes (ADR-0124 §3): `call <name> ok`, or the
            // exception it met.
            Namespace ns = Namespace.of("callsns");
            TableIdentifier t = TableIdentifier.of(ns, "t1");
            // A HashMap: Iceberg Java's request builder asks the map for a null key, which Map.of's refuse.
            Map<String, String> owner = new HashMap<>();
            owner.put("owner", "check");
            call("create-namespace", () -> c.createNamespace(ns, owner));
            call("namespace-exists", () -> { if (!c.namespaceExists(ns)) throw new RuntimeException("not there"); });
            call("load-namespace", () -> { if (!c.loadNamespaceMetadata(ns).containsKey("owner")) throw new RuntimeException("no owner"); });
            // Refused by design, as S3 Tables does: a namespace keeps only its `owner`, set at its create.
            call("set-namespace-properties", () -> c.setProperties(ns, Map.of("k", "v")));
            call("remove-namespace-properties", () -> c.removeProperties(ns, java.util.Set.of("owner")));
            call("list-namespaces", () -> { if (!c.listNamespaces().contains(ns)) throw new RuntimeException("not listed"); });
            call("create-table", () -> c.createTable(t, SCHEMA));
            call("table-exists", () -> { if (!c.tableExists(t)) throw new RuntimeException("not there"); });
            call("list-tables", () -> { if (!c.listTables(ns).contains(t)) throw new RuntimeException("not listed"); });
            call("append", () -> { Table tb = c.loadTable(t); tb.newAppend().appendFile(writeFileIn(tb, 0, 3)).commit(); });
            call("update-schema", () -> c.loadTable(t).updateSchema().addColumn("more", Types.IntegerType.get()).commit());
            call("update-spec", () -> c.loadTable(t).updateSpec().addField("id").commit());
            call("replace-sort-order", () -> c.loadTable(t).replaceSortOrder().asc("id").commit());
            call("update-properties", () -> c.loadTable(t).updateProperties().set("p", "q").commit());
            call("tag", () -> { Table tb = c.loadTable(t); tb.manageSnapshots().createTag("v1", tb.currentSnapshot().snapshotId()).commit(); });
            call("branch", () -> { Table tb = c.loadTable(t); tb.manageSnapshots().createBranch("b1", tb.currentSnapshot().snapshotId()).commit(); });
            call("expire-snapshots", () -> c.loadTable(t).expireSnapshots().expireOlderThan(System.currentTimeMillis()).retainLast(1).commit());
            call("rename-table", () -> c.renameTable(t, TableIdentifier.of(ns, "t2")));
            call("register-table", () -> {
                Table tb = c.loadTable(TableIdentifier.of(ns, "t2"));
                String loc = ((HasTableOperations) tb).operations().current().metadataFileLocation();
                c.registerTable(TableIdentifier.of(ns, "t3"), loc);
            });
            call("drop-table-purge", () -> { if (!c.dropTable(TableIdentifier.of(ns, "t2"), true)) throw new RuntimeException("not dropped"); });
            call("drop-namespace-nonempty", () -> {
                c.createTable(TableIdentifier.of(ns, "t9"), SCHEMA);
                try {
                    c.dropNamespace(ns);
                    throw new RuntimeException("dropped with a table in it");
                } catch (org.apache.iceberg.exceptions.NamespaceNotEmptyException e) {
                    // as it should
                }
            });
            call("drop-namespace", () -> {
                c.dropTable(TableIdentifier.of(ns, "t9"), true);
                if (!c.dropNamespace(ns)) throw new RuntimeException("not dropped");
            });
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
