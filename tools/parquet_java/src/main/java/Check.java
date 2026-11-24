import java.io.File;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import org.apache.avro.file.DataFileReader;
import org.apache.avro.generic.GenericDatumReader;
import org.apache.avro.generic.GenericRecord;
import org.apache.parquet.column.statistics.Statistics;
import org.apache.parquet.example.data.Group;
import org.apache.parquet.hadoop.ParquetFileReader;
import org.apache.parquet.hadoop.ParquetReader;
import org.apache.parquet.hadoop.api.ReadSupport;
import org.apache.parquet.hadoop.example.GroupReadSupport;
import org.apache.parquet.hadoop.metadata.BlockMetaData;
import org.apache.parquet.hadoop.metadata.ColumnChunkMetaData;
import org.apache.parquet.hadoop.metadata.CompressionCodecName;
import org.apache.parquet.io.InputFile;
import org.apache.parquet.io.LocalInputFile;

/**
 * parquet-java reads the page writer's files (ADR-0118 §6), each beside the pyarrow fixture it was written from:
 * - the same rows, each as parquet-java's example reader prints it (so -0.0 and 0.0 differ, and NaN is NaN);
 * - each chunk found by its path in the fixture's schema (the M23 exit review's B4);
 * - each chunk's min and max equal to the fixture's, by parquet-java's comparator for the column's type (B2);
 * - uncompressed, each chunk's total uncompressed size equal to its compressed size (B3).
 * And Avro Java reads the Avro test's manifest in each codec as the same records (the M25 exit review's B1).
 *
 * usage: java Check WRITTEN_DIR FIXTURES_DIR AVRO_DIR
 */
public class Check {
    static int failed = 0;
    static int passed = 0;

    static void check(String what, boolean ok, String detail) {
        if (ok) {
            passed++;
        } else {
            failed++;
            System.out.println("FAIL " + what + (detail.isEmpty() ? "" : ": " + detail));
        }
    }

    static List<String> rows(Path p) throws Exception {
        InputFile in = new LocalInputFile(p);
        List<String> out = new ArrayList<>();
        try (ParquetReader<Group> r = new ParquetReader.Builder<Group>(in) {
            @Override
            protected ReadSupport<Group> getReadSupport() {
                return new GroupReadSupport();
            }
        }.build()) {
            Group g;
            while ((g = r.read()) != null) {
                out.add(g.toString());
            }
        }
        return out;
    }

    static Map<String, ColumnChunkMetaData> chunks(ParquetFileReader r) {
        Map<String, ColumnChunkMetaData> out = new HashMap<>();
        for (BlockMetaData b : r.getFooter().getBlocks()) {
            for (ColumnChunkMetaData c : b.getColumns()) {
                // A path's names joined by NUL, so `a.b` and `a`, `b` differ.
                out.putIfAbsent(String.join("\0", c.getPath().toArray()), c);
            }
        }
        return out;
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    static boolean sameBound(Statistics a, Comparable x, Comparable y) {
        return a.comparator().compare(x, y) == 0;
    }

    public static void main(String[] args) throws Exception {
        File written = new File(args[0]);
        File fixtures = new File(args[1]);
        String[] names = written.list();
        Arrays.sort(names);
        int files = 0;
        for (String name : names) {
            if (!name.endsWith(".parquet")) continue;
            files++;
            String fixture = name.substring(0, name.lastIndexOf('-'));
            Path w = new File(written, name).toPath();
            Path f = new File(fixtures, fixture + ".parquet").toPath();
            List<String> got = rows(w);
            List<String> want = rows(f);
            check(name + ": its rows as the fixture's", got.equals(want), got.size() + " rows, the fixture's " + want.size());
            try (ParquetFileReader wr = ParquetFileReader.open(new LocalInputFile(w));
                 ParquetFileReader fr = ParquetFileReader.open(new LocalInputFile(f))) {
                Map<String, ColumnChunkMetaData> fixtureChunks = chunks(fr);
                for (BlockMetaData b : wr.getFooter().getBlocks()) {
                    for (ColumnChunkMetaData c : b.getColumns()) {
                        String path = String.join(".", c.getPath().toArray());
                        ColumnChunkMetaData fc = fixtureChunks.get(String.join("\0", c.getPath().toArray()));
                        check(name + ": " + path + "'s path in the fixture's schema", fc != null, "");
                        if (fc == null) continue;
                        Statistics<?> ws = c.getStatistics();
                        Statistics<?> fs = fc.getStatistics();
                        check(name + ": " + path + "'s null count", ws.getNumNulls() == fs.getNumNulls(),
                            ws.getNumNulls() + " against " + fs.getNumNulls());
                        if (fs.hasNonNullValue() && fr.getFooter().getBlocks().size() == 1) {
                            boolean has = ws.hasNonNullValue();
                            check(name + ": " + path + " has bounds, as the fixture", has, "");
                            if (has) {
                                check(name + ": " + path + "'s min", sameBound(fs, ws.genericGetMin(), fs.genericGetMin()),
                                    ws.minAsString() + " against " + fs.minAsString());
                                check(name + ": " + path + "'s max", sameBound(fs, ws.genericGetMax(), fs.genericGetMax()),
                                    ws.maxAsString() + " against " + fs.maxAsString());
                            }
                        }
                        if (c.getCodec() == CompressionCodecName.UNCOMPRESSED) {
                            check(name + ": " + path + "'s uncompressed size, its bytes",
                                c.getTotalUncompressedSize() == c.getTotalSize(),
                                c.getTotalUncompressedSize() + " against " + c.getTotalSize());
                        }
                    }
                }
            }
        }
        check("files written", files > 0, "none in " + written);
        // The manifests: each codec's records as the null codec's.
        File avro = new File(args[2]);
        List<String> plain = null;
        Map<String, List<String>> byCodec = new HashMap<>();
        for (String name : avro.list()) {
            if (!name.endsWith(".avro")) continue;
            try (DataFileReader<GenericRecord> r = new DataFileReader<>(new File(avro, name), new GenericDatumReader<>())) {
                List<String> records = new ArrayList<>();
                for (GenericRecord g : r) records.add(g.toString());
                String codec = r.getMetaString("avro.codec");
                byCodec.put(codec == null ? "null" : codec, records);
            }
        }
        plain = byCodec.get("null");
        check("a manifest in the null codec", plain != null, "");
        for (String codec : new String[] {"deflate", "snappy", "zstandard"}) {
            List<String> got = byCodec.get(codec);
            check("a manifest in " + codec + ", its records the null codec's", got != null && got.equals(plain), "");
        }
        System.out.println("parquet-java check: " + passed + " passed, " + failed + " failed, " + files + " files");
        System.exit(failed == 0 ? 0 : 1);
    }
}
